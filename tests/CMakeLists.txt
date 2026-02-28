cmake_minimum_required(VERSION 3.16)

# ── gen_blob: deterministic binary generator ─────────────────────────────────
add_executable(gen_blob gen_blob.c)

# ── blobs directory (created at configure time) ──────────────────────────────
set(BLOBS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/blobs)
file(MAKE_DIRECTORY ${BLOBS_DIR})

# ── helper: register a round-trip test ───────────────────────────────────────
# add_roundtrip_test(name MODE SEED SIZE N_FILES [T2SZ_FLAGS...])
#
#   MODE     : raw | tar | empty_tar
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
    set_tests_properties(${name} PROPERTIES TIMEOUT 300)
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
    set_tests_properties(${name} PROPERTIES TIMEOUT 30)
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
        if(APPLE)
            # LeakSanitizer (LSAN) is not supported on macOS Apple Silicon.
            # detect_leaks=1 would cause an immediate abort — omit it here.
            set_tests_properties(${name} PROPERTIES
                ENVIRONMENT "ASAN_OPTIONS=halt_on_error=1:print_stats=1")
        else()
            # All memory leaks in t2sz.c have been fixed; no LSAN suppressions needed.
            set_tests_properties(${name} PROPERTIES
                ENVIRONMENT "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:print_stats=1")
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

# Large files (skipped automatically if disk space < 5 GB)
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
add_error_test(err_version           version)

# ── File-system error paths ────────────────────────────────────────────────────
add_error_test(err_file_not_found    file_not_found)
add_error_test(err_output_bad_path   output_bad_path)

# ── Interactive overwrite prompt ───────────────────────────────────────────────
add_error_test(err_overwrite_no      overwrite_no)
add_error_test(err_overwrite_yes     overwrite_yes)

# ── Corrupted tar — isTarHeader() checksum-mismatch error path ────────────────
add_error_test(err_corrupt_tar       corrupt_tar)

# ── Auto raw-mode detection — strEndsWith() branch in main() ─────────────────
add_error_test(err_auto_raw          auto_raw)

# ── Default output filename — getOutFilename() called when -o is omitted ──────
add_error_test(err_auto_outname      auto_outname)

# ── decodeMultiplier metric suffixes (GiB/kB/KB/MB/GB) ───────────────────────
add_error_test(err_multiplier_suffixes  multiplier_suffixes)

# ── Apply COVERAGE / SANITIZE env vars to all tests ──────────────────────────
foreach(tname
    raw_1mb raw_100mb
    raw_1mb_s256k raw_1mb_noseek raw_1mb_level1 raw_1mb_level22
    tar_single tar_multi tar_multi_s512k tar_big_S1M tar_multi_sS tar_multi_threads
    empty_tar raw_1gb tar_500mb
    tar_single_v raw_1mb_v tar_unaligned
    err_no_args err_too_many_args
    err_bad_level_low err_bad_level_high
    err_bad_block_s err_bad_block_S
    err_bad_threads err_block_S_lt_s
    err_help err_version
    err_file_not_found err_output_bad_path
    err_overwrite_no err_overwrite_yes
    err_corrupt_tar err_auto_raw
    err_auto_outname err_multiplier_suffixes)
    set_test_env(${tname})
endforeach()
