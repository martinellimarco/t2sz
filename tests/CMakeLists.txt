cmake_minimum_required(VERSION 3.16)

set(CMAKE_C_STANDARD 17)

# ── gen_blob: deterministic binary generator ─────────────────────────────────
add_executable(gen_blob gen_blob.c)

# ── blobs directory (created at configure time) ──────────────────────────────
set(BLOBS_DIR ${CMAKE_CURRENT_BINARY_DIR}/blobs)
file(MAKE_DIRECTORY ${BLOBS_DIR})

# ── helper: register a round-trip test ───────────────────────────────────────
# add_roundtrip_test(name MODE SEED SIZE N_FILES [T2SZ_FLAGS...])
#
#   MODE     : raw | tar | empty_tar | stdin
#   SEED     : integer seed for gen_blob
#   SIZE     : file size in bytes (per file)
#   N_FILES  : number of files in the tar (1 for raw; ignored for empty_tar)
#   T2SZ_FLAGS : remaining args forwarded verbatim to t2sz
function(add_roundtrip_test name)
    add_test(
        NAME    ${name}
        COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_roundtrip.sh
                    $<TARGET_FILE:t2sz>
                    $<TARGET_FILE:gen_blob>
                    ${BLOBS_DIR}
                    ${ARGN}
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )
    set_tests_properties(${name} PROPERTIES TIMEOUT 300 SKIP_RETURN_CODE 77)
    set_test_env(${name})
endfunction()

# ── helper: register a CLI / error-path test ─────────────────────────────────
# add_error_test(name test_id)
#
#   name    : CTest test name
#   test_id : TEST_NAME string passed to test_error_paths.sh
function(add_error_test name test_id)
    add_test(
        NAME    ${name}
        COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_error_paths.sh
                    $<TARGET_FILE:t2sz>
                    ${BLOBS_DIR}
                    ${test_id}
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    )
    set_tests_properties(${name} PROPERTIES TIMEOUT 30 SKIP_RETURN_CODE 77)
    set_test_env(${name})
endfunction()

# ── LLVM_PROFILE_FILE for coverage builds ────────────────────────────────────
if(COVERAGE)
    set(PROF_ENV "LLVM_PROFILE_FILE=${CMAKE_BINARY_DIR}/cov_%p.profraw")
endif()

function(set_test_env name)
    if(COVERAGE)
        set_tests_properties(${name} PROPERTIES ENVIRONMENT "${PROF_ENV}")
    endif()
    if(SANITIZE)
        # A sanitizer error exits with 66, which no test accepts: t2sz's own
        # failures exit with 1, and the default 1 would pass for one of them.
        set(UBSAN_ENV "UBSAN_OPTIONS=print_stacktrace=1:exitcode=66")
        if(APPLE)
            # LeakSanitizer (LSAN) is not supported on macOS Apple Silicon.
            # detect_leaks=1 would cause an immediate abort — omit it here.
            set_tests_properties(${name} PROPERTIES
                ENVIRONMENT "ASAN_OPTIONS=halt_on_error=1:print_stats=1:exitcode=66;${UBSAN_ENV}")
        else()
            # All memory leaks in t2sz.c have been fixed; no LSAN suppressions needed.
            set_tests_properties(${name} PROPERTIES
                ENVIRONMENT "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:print_stats=1:exitcode=66;${UBSAN_ENV}")
        endif()
    endif()
endfunction()

# ── Test matrix ───────────────────────────────────────────────────────────────

# Raw mode — baseline
add_roundtrip_test(raw_1mb           raw   1  1048576    1)
add_roundtrip_test(raw_100mb         raw   2  104857600  1)

# Raw mode — with flags
add_roundtrip_test(raw_1mb_s256k     raw   3  1048576    1  -s  256k)
add_roundtrip_test(raw_1mb_noseek    raw   4  1048576    1  -j)
add_roundtrip_test(raw_1mb_level1    raw   5  1048576    1  -l  1)
add_roundtrip_test(raw_1mb_level22   raw   6  1048576    1  -l  22)

# Tar mode — single file
add_roundtrip_test(tar_single        tar   7  1048576    1)

# Tar mode — multi file
add_roundtrip_test(tar_multi         tar   8  524288     10)
add_roundtrip_test(tar_multi_s512k   tar   9  524288     10  -s  512k)
add_roundtrip_test(tar_big_S1M       tar   10 5242880    1   -S  1M)
add_roundtrip_test(tar_multi_sS      tar   11 524288     10  -s  256k  -S  2M)
add_roundtrip_test(tar_multi_threads tar   12 524288     10  -T  2)

# Edge case: tar with one zero-byte file
add_roundtrip_test(empty_tar         empty_tar  0  0  1)
set_tests_properties(empty_tar PROPERTIES TIMEOUT 30)

# Large files (auto-skipped when disk space is tight: ~4 GB for raw_1gb, ~2 GB for tar_500mb)
add_roundtrip_test(raw_1gb           raw   99 1073741824  1)
add_roundtrip_test(tar_500mb         tar   98 524288000   1)
set_tests_properties(raw_1gb tar_500mb PROPERTIES
    TIMEOUT      600
    SKIP_RETURN_CODE 77)

# ── Verbose mode — exercises all ctx->verbose fprintf() branches ──────────────
# These cover the verbose output paths inside compressFile() and writeSeekTable()
# that are never reached by non-verbose round-trip tests.
add_roundtrip_test(tar_single_v   tar   7  1048576  1  -v)
add_roundtrip_test(raw_1mb_v      raw   1  1048576  1  -v)

# ── Non-512-aligned file size — exercises the tar header padding branch ───────
# size % 512 = 1000 % 512 = 488 ≠ 0, so the `if(mod)` rounding path is taken.
add_roundtrip_test(tar_unaligned  tar   20 1000     1)

# ── CLI validation ─────────────────────────────────────────────────────────────
# Each test exercises one argument-validation branch that calls usage() or
# returns an error before any file I/O occurs.
add_error_test(err_no_args           no_args)
add_error_test(err_too_many_args     too_many_args)
add_error_test(err_bad_level_low     bad_level_low)
add_error_test(err_bad_level_high    bad_level_high)
add_error_test(err_bad_block_s       bad_block_s)
add_error_test(err_bad_block_S       bad_block_S)
add_error_test(err_bad_threads       bad_threads)
add_error_test(err_block_S_lt_s      block_S_lt_s)
add_error_test(err_help              help)
add_error_test(err_help_program_name help_program_name)
add_error_test(err_version           version)

# ── File-system error paths ────────────────────────────────────────────────────
add_error_test(err_file_not_found    file_not_found)
add_error_test(err_output_bad_path   output_bad_path)
add_error_test(err_close_error_exit  close_error_exit)

# ── Interactive overwrite prompt ───────────────────────────────────────────────
add_error_test(err_overwrite_no      overwrite_no)
add_error_test(err_overwrite_yes     overwrite_yes)

# ── Corrupted tar — isTarHeader() checksum-mismatch error path ────────────────
add_error_test(err_corrupt_tar       corrupt_tar)
add_error_test(err_git_archive_checksum git_archive_checksum)

# ── Auto raw-mode detection — strEndsWith() branch in main() ─────────────────
add_error_test(err_auto_raw          auto_raw)

# ── Default output filename — getOutFilename() called when -o is omitted ──────
add_error_test(err_auto_outname      auto_outname)

# ── decodeMultiplier metric suffixes (GiB/kB/KB/MB/GB) ───────────────────────
add_error_test(err_multiplier_suffixes  multiplier_suffixes)

# ── Stdin / stdout support ────────────────────────────────────────────────────
# Each sub_mode is passed as the first positional arg after N_FILES; the test
# script uses it to select the stdin/stdout scenario to exercise.
add_roundtrip_test(stdin_raw_to_file   stdin  30  1048576  1  raw_to_file)
add_roundtrip_test(stdin_tar_to_file   stdin  31  1048576  1  tar_to_file)
add_roundtrip_test(stdin_raw_to_stdout stdin  32  1048576  1  raw_to_stdout)

add_error_test(err_stdin_empty_raw       stdin_empty_raw)
add_error_test(err_stdin_empty_tar_mode  stdin_empty_tar_mode)
add_error_test(err_mmap_tiny_tar         mmap_tiny_tar)
add_error_test(err_stdin_default_stdout  stdin_default_stdout)
add_error_test(err_closed_stderr         closed_stderr)
add_error_test(err_stdin_file_stdout    stdin_file_stdout)

# ── Stdin + raw mode with flags ──────────────────────────────────────────────
add_roundtrip_test(stdin_raw_s256k        stdin  33  1048576    1   raw_to_file  -s  256k)
add_roundtrip_test(stdin_raw_noseek       stdin  34  1048576    1   raw_to_file  -j)
add_roundtrip_test(stdin_raw_v            stdin  35  1048576    1   raw_to_file  -v)

# ── Stdin + tar mode with flags (single file) ───────────────────────────────
add_roundtrip_test(stdin_tar_S1M          stdin  36  5242880    1   tar_to_file  -S  1M)
add_roundtrip_test(stdin_tar_v            stdin  37  1048576    1   tar_to_file  -v)

# ── Stdin + tar mode with flags (multi file) ────────────────────────────────
add_roundtrip_test(stdin_tar_multi        stdin  38  524288     10  tar_multi_to_file)
add_roundtrip_test(stdin_tar_multi_s512k  stdin  39  102400     10  tar_multi_to_file  -s  512k)
add_roundtrip_test(stdin_tar_multi_sS     stdin  40  524288     10  tar_multi_to_file  -s  256k  -S  2M)

# ── Stdin → stdout (full pipe, tar mode) ─────────────────────────────────────
add_roundtrip_test(stdin_tar_to_stdout    stdin  41  1048576    1   tar_to_stdout)

# ── Stdin streaming error paths ──────────────────────────────────────────────
add_error_test(err_stdin_corrupt_tar       stdin_corrupt_tar)
add_error_test(err_failed_run_leaves_output failed_run_leaves_output)
add_error_test(err_stdin_empty_tar         stdin_empty_tar)
add_error_test(err_stdin_truncated_tar     stdin_truncated_tar)
add_error_test(err_stdin_truncated_payload stdin_truncated_payload)
add_error_test(err_stdout_tar_file         stdout_tar_file)
add_error_test(err_empty_file              empty_file)

# ── Seek table structural verification ──────────────────────────────────────
add_error_test(err_noseek_verify             noseek_verify)
add_error_test(err_noseek_tar                noseek_tar)

# ── Raw -s with non-multiple input size ─────────────────────────────────────
add_error_test(err_raw_nonmultiple_s         raw_nonmultiple_s)
add_error_test(err_stdin_raw_nonmultiple_s   stdin_raw_nonmultiple_s)

# ── Tar trailing junk after end-of-archive ──────────────────────────────────
add_error_test(err_trailing_junk_tar         trailing_junk_tar)

# ── Non-regular tar entries (dirs, symlinks) ────────────────────────────────
add_error_test(err_tar_with_dirs_symlinks    tar_with_dirs_symlinks)

# ── Explicit -o - with stdin ────────────────────────────────────────────────
add_error_test(err_stdin_explicit_stdout_raw stdin_explicit_stdout_raw)
add_error_test(err_fifo_input                fifo_input)
add_error_test(err_stdin_explicit_stdout_tar stdin_explicit_stdout_tar)

# ── Argument parsing edge cases: strtol failures, negative, overflow ───────
add_error_test(err_bad_level_strtol          bad_level_strtol)
add_error_test(err_bad_block_s_strtol        bad_block_s_strtol)
add_error_test(err_bad_block_S_strtol        bad_block_S_strtol)
add_error_test(err_bad_threads_strtol        bad_threads_strtol)

# ── Unknown option — getopt default case ────────────────────────────────────
add_error_test(err_unknown_option            unknown_option)

# ── decodeMultiplier extra suffixes (K/KiB/MiB/G) ─────────────────────────
add_error_test(err_multiplier_suffixes_extra multiplier_suffixes_extra)

# ── Stdin overwrite protection ────────────────────────────────────────────
add_error_test(err_stdin_overwrite_no_force  stdin_overwrite_no_force)
add_error_test(err_stdin_overwrite_force     stdin_overwrite_force)

# ── Overflow guard for -s/-S multiplication ──────────────────────────────
add_error_test(err_overflow_s               overflow_s)
add_error_test(err_overflow_S               overflow_S)

# ── seekTableEnsureCap realloc growth (>1024 frames) ──────────────────────
add_error_test(err_seektable_grow            seektable_grow)

# ── Garbage between number and suffix in -s/-S ──────────────────────────
add_error_test(err_garbage_suffix            garbage_suffix)
