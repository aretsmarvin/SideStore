#ifdef MDC
#pragma once
#include <stdlib.h>
#include <stdbool.h>
/// Uses CVE-2022-46689 to overwrite `overwrite_length` bytes of `file_to_overwrite` with `overwrite_data`, starting from `file_offset`.
/// `file_to_overwrite` should be a file descriptor opened with O_RDONLY.
/// `overwrite_length` must be less than or equal to `PAGE_SIZE`.
/// Returns `true` if the overwrite succeeded, and `false` if the device is not vulnerable.
bool unalign_csr(int file_to_bake, off_t the_offset_of_the_file, const void* what_do_we_overwrite_this_file_with, size_t what_is_the_length_of_this_overwrite_data);
#endif /* MDC */