# Testing

## Overview

The test suite exercises t2sz across three dimensions:

| Dimension          | Tool                           | What it catches                                         |
|--------------------|--------------------------------|---------------------------------------------------------|
| **Correctness**    | round-trip + SHA-256           | compression/decompression produces bit-identical output |
| **Seek table**     | binary footer parsing          | seek table presence, magic numbers, frame count         |
| **Memory safety**  | AddressSanitizer + UBSanitizer | buffer overflows, use-after-free, undefined behaviour   |
| **Code coverage**  | LLVM coverage + llvm-cov       | dead or untested code paths                             |

76 tests in total: 30 round-trip tests and 46 CLI/error/edge-case tests.
All three build configurations run the same 76 tests.

---

## Prerequisites

| Dependency                         | Required for         | macOS                             | Linux                     |
|------------------------------------|----------------------|-----------------------------------|---------------------------|
| `cmake ≥ 3.16`                     | all builds           | `brew install cmake`              | `apt install cmake`       |
| `libzstd-dev`                      | all builds           | `brew install zstd`               | `apt install libzstd-dev` |
| `zstd` CLI                         | round-trip tests     | included with `brew install zstd` | `apt install zstd`        |
| LLVM (`llvm-cov`, `llvm-profdata`) | coverage report only | `brew install llvm`               | `apt install llvm`        |

---

## Quick start

```bash
cmake -B build -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cd build && ctest --output-on-failure
```

Expected output: `100% tests passed, 0 tests failed out of 76`

---

## Build configurations

### Debug (correctness)

Builds t2sz and the test helpers without any instrumentation.
Use this for day-to-day development.

```bash
cmake -B build -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cd build && ctest --output-on-failure -j4
```

### ASAN + UBSan (memory safety)

Compiles with `-fsanitize=address,undefined`. Any memory violation or
undefined behaviour causes the affected test to fail with a detailed report
on stderr. On Linux, LeakSanitizer is also enabled (`detect_leaks=1`); on
macOS Apple Silicon it is omitted as LSAN is not supported there.

```bash
cmake -B build_asan -DBUILD_TESTS=ON -DSANITIZE=ON
cmake --build build_asan
cd build_asan && ctest --output-on-failure -j4
```

### Coverage (LLVM)

Compiles with `-fprofile-instr-generate -fcoverage-mapping` and emits one
`.profraw` file per test run. After all tests complete, `test_coverage.sh`
merges the profiles and generates an HTML report.

```bash
cmake -B build_cov -DBUILD_TESTS=ON -DCOVERAGE=ON
cmake --build build_cov
cd build_cov && ctest --output-on-failure -j4

# Generate the HTML report (opens automatically on macOS)
bash ../tests/test_coverage.sh ../build_cov
# Report: tests/coverage/html/index.html
```

> **Note — LLVM path on macOS**
> `test_coverage.sh` looks for `llvm-cov` and `llvm-profdata` first in
> `/opt/homebrew/opt/llvm/bin` (Apple Silicon Homebrew) and falls back to
> the system `PATH`. If coverage report generation fails, verify that
> `brew install llvm` has been run.

---

## Test categories

### File input (mmap path)

| Category                  | Tests                                                                                                                                      | What is covered                                                      |
|---------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| Raw round-trip — baseline | `raw_1mb`, `raw_100mb`                                                                                                                     | basic `-r` compression + SHA-256 verification                        |
| Raw round-trip — flags    | `raw_1mb_s256k`, `raw_1mb_noseek`, `raw_1mb_level1`, `raw_1mb_level22`                                                                     | `-s`, `-j`, `-l` flag paths                                          |
| Raw round-trip — large    | `raw_1gb`                                                                                                                                  | 1 GB file (auto-skipped if disk < ~4 GB)                             |
| Tar round-trip — single   | `tar_single`                                                                                                                               | basic tar mode                                                       |
| Tar round-trip — multi    | `tar_multi`, `tar_multi_s512k`, `tar_big_S1M`, `tar_multi_sS`, `tar_multi_threads`                                                         | multi-file archives, `-s`, `-S`, `-T`                                |
| Tar round-trip — large    | `tar_500mb`                                                                                                                                | 500 MB tar (auto-skipped if disk < ~2 GB)                            |
| Verbose mode              | `tar_single_v`, `raw_1mb_v`                                                                                                                | all `-v` logging paths in `compressFile()` and `writeSeekTable()`    |
| Edge cases                | `empty_tar`, `tar_unaligned`                                                                                                               | zero-byte file in tar; file size not aligned to 512 bytes            |

### Stdin / stdout (streaming path)

| Category                   | Tests                                                                                                    | What is covered                                                                                                                                       |
|----------------------------|----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| Stdin raw — baseline       | `stdin_raw_to_file`, `stdin_raw_to_stdout`                                                               | `compressStdinRaw()` single-frame streaming (pledged unknown)                                                                                         |
| Stdin raw — flags          | `stdin_raw_s256k`, `stdin_raw_noseek`, `stdin_raw_v`                                                     | `compressStdinRaw()` fixed-frame path (`-s`), skip seek table (`-j`), verbose                                                                         |
| Stdin tar — single file    | `stdin_tar_to_file`, `stdin_tar_S1M`, `stdin_tar_v`                                                      | `compressStdinTar()` baseline, maxBlockSize splitting (`-S`), verbose                                                                                 |
| Stdin tar — multi file     | `stdin_tar_multi`, `stdin_tar_multi_s512k`, `stdin_tar_multi_sS`                                         | multi-file tar from stdin, minBlockSize aggregation (`-s`), combined (`-s` + `-S`)                                                                    |
| Stdin → stdout (full pipe) | `stdin_tar_to_stdout`                                                                                    | stdin and stdout simultaneously in tar mode                                                                                                           |
| Stdin error paths          | `err_stdin_empty_raw`, `err_stdin_default_stdout`, `err_stdin_file_stdout`                               | empty stdin, default stdout fallback, explicit `-o -`                                                                                                 |
| Stdin streaming errors     | `err_stdin_corrupt_tar`, `err_stdin_empty_tar`, `err_stdin_truncated_tar`, `err_stdin_truncated_payload` | `isTarHeader()` failure via stdin, `isZeroTarBlock()` zero-block handling, truncated header (`r != 512`), `readExactStdin()` EOF on truncated payload |
| Stdout from file           | `err_stdout_tar_file`                                                                                    | mmap path with `-o -` (stdout output from file input, tar mode)                                                                                       |
| Explicit `-o -` + stdin    | `err_stdin_explicit_stdout_raw`, `err_stdin_explicit_stdout_tar`                                         | stdoutMode set via explicit `-o -` when input is also stdin, raw and tar modes                                                                        |

### CLI validation and error paths

| Category            | Tests                                                                                                                                      | What is covered                                                                                                                      |
|---------------------|--------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| CLI validation      | `err_no_args`, `err_too_many_args`, `err_bad_level_*`, `err_bad_block_*`, `err_bad_threads`, `err_block_S_lt_s`, `err_help`, `err_version` | all `usage()` and argument-check branches                                                                                            |
| strtol edge cases   | `err_bad_level_strtol`, `err_bad_block_s_strtol`, `err_bad_block_S_strtol`, `err_bad_threads_strtol`                                       | `endptr == optarg`, `*endptr != '\0'` (trailing garbage), `ERANGE`, negative values, `val > UINT32_MAX`                              |
| Unknown option      | `err_unknown_option`                                                                                                                       | getopt `'?'` → `switch default` case → `usage("ERROR: Unknown option")` → exit 1                                                     |
| File-system errors  | `err_file_not_found`, `err_output_bad_path`, `err_empty_file`                                                                              | `access()` failure, `fopen()` failure in `prepareOutput()`, zero-byte input file (`prepareInput()`)                                  |
| Overwrite prompt    | `err_overwrite_no`, `err_overwrite_yes`                                                                                                    | `scanf` branch: answer `n` (no overwrite) and `y` (overwrite)                                                                        |
| Stdin overwrite     | `err_stdin_overwrite_no_force`, `err_stdin_overwrite_force`                                                                                | stdinMode + existing file: error without `-f`, success with `-f` (no `scanf` corruption)                                             |
| Overflow guard      | `err_overflow_s`, `err_overflow_S`                                                                                                         | `(size_t)val > SIZE_MAX / multiplier` for `-s` and `-S` (huge value × large suffix)                                                  |
| Corrupted input     | `err_corrupt_tar`                                                                                                                          | `isTarHeader()` checksum-mismatch path in mmap mode                                                                                  |
| Auto raw-mode       | `err_auto_raw`                                                                                                                             | `strEndsWith()` branch: non-`.tar` file treated as raw automatically                                                                 |
| Default output name | `err_auto_outname`                                                                                                                         | `getOutFilename()` called when `-o` is omitted                                                                                       |
| Size suffixes       | `err_multiplier_suffixes`, `err_multiplier_suffixes_extra`, `err_garbage_suffix`                                                           | `decodeMultiplier()` all branches: `GiB`, `kB`, `KB`, `MB`, `GB`, `K`, `KiB`, `MiB`, `G`; garbage between number and suffix rejected |

### Seek table and structural verification

| Category                  | Tests                         | What is covered                                                                                  |
|---------------------------|-------------------------------|--------------------------------------------------------------------------------------------------|
| Seek table on-disk        | all 30 round-trip tests       | every round-trip verifies seek table magic, descriptor, Frame_Size, and Number_Of_Frames on disk |
| No-seek-table (`-j`)      | `err_noseek_verify`           | verifies seekable magic `0x8F92EAB1` is absent when `-j` flag is used                            |
| Non-multiple `-s` (mmap)  | `err_raw_nonmultiple_s`       | 1000001 bytes with `-s 256k`: partial last frame + seek table with 4 frames                      |
| Non-multiple `-s` (stdin) | `err_stdin_raw_nonmultiple_s` | same via stdin: `compressStdinRaw()` Path B partial last frame                                   |
| Trailing junk after tar   | `err_trailing_junk_tar`       | 1024 bytes of 0xAA appended after end-of-archive: both mmap and stdin must not crash             |
| Non-regular tar entries   | `err_tar_with_dirs_symlinks`  | directory + symlink + regular file: round-trip + seek table structure verification               |
| Seek table capacity grow  | `err_seektable_grow`          | 1025×1k raw → 1026 frames, forces `seekTableEnsureCap()` realloc from 1024 to 2048 entries       |

Large tests (`raw_1gb`, `tar_500mb`) return exit code 77 when disk space is insufficient; CTest treats this as a skip rather than a failure.

---

## Coverage results

Current numbers measured on macOS Apple Silicon (AppleClang 17, libzstd 1.5.x).
Re-run `tests/test_coverage.sh` after changes to get exact figures.

### What is not covered (and why)

The uncovered lines consist of defensive error-handling branches that cannot be
reached without hardware or environment conditions outside normal test execution:

- **Big-endian path in `writeLE32`** — x86-64 and ARM64 are always little-endian.
- **`prepareInput` I/O failures** — `open()` after a successful `access()` (TOCTOU race); `mmap()` failure requires OS-level fault injection.
- **`prepareCctx` failures** — `ZSTD_createCCtx()` returning NULL requires memory exhaustion; parameter errors require a broken libzstd build.
- **`compressFile` fatal paths** — "This is a bug" branch is structurally unreachable; `ZSTD_compressStream2` error requires a corrupt compression context.
- **`seekTableAdd` overflow guards** — triggered only by > 134 million frames or a single block > 2 GB.
- **Multi-thread fallback** — requires libzstd built without `ZSTD_MULTITHREAD`.
- **`malloc` failure paths** — `newContext()`, `getOutFilename()`, `prepareOutput()`, `compressStdinRaw()`, `compressStdinTar()` all have OOM guards that require memory exhaustion.
- **`ferror(stdin)` paths** — `compressStdinRaw()` and `compressStdinTar()` handle read errors on stdin, but bash pipe redirection does not simulate I/O errors.

These are defensive guards, not untested logic.

## Testing GitHub Actions

To test GitHub Actions locally, you can use the `act` tool. Install it with `brew install act` and then run it in the repository root.

This will simulate the GitHub Actions environment locally, allowing you to test your workflows and jobs without pushing to GitHub.

```bash
act --container-architecture linux/amd64 \
    -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
    push
```