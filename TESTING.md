# Testing

## Overview

The test suite exercises t2sz across three dimensions:

| Dimension          | Tool                           | What it catches                                         |
|--------------------|--------------------------------|---------------------------------------------------------|
| **Correctness**    | round-trip + SHA-256           | compression/decompression produces bit-identical output |
| **Seek table**     | binary footer parsing          | seek table presence, magic numbers, frame count         |
| **Memory safety**  | AddressSanitizer + UBSanitizer | buffer overflows, use-after-free, undefined behaviour   |
| **Code coverage**  | LLVM coverage + llvm-cov       | dead or untested code paths                             |

Round-trip tests check the decompressed output against the input; CLI/error/edge-case
tests check exit codes, messages and output structure. All three build
configurations run the same tests.

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

Expected output: `100% tests passed, 0 tests failed out of N`

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

Compiles with `-fsanitize=address,undefined -fno-sanitize-recover=undefined`.
Any memory violation or undefined behaviour stops t2sz with a detailed report
on stderr and exit code 66, which no test accepts (t2sz itself fails with 1),
so the affected test fails. On Linux, LeakSanitizer is also enabled
(`detect_leaks=1`); on macOS Apple Silicon it is omitted as LSAN is not
supported there.

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

| Category                   | Tests                                                                                                                             | What is covered                                                                                                                                                                  |
|----------------------------|-----------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Raw round-trip — baseline  | `raw_1mb`, `raw_100mb`                                                                                                            | basic `-r` compression + SHA-256 verification                                                                                                                                    |
| Raw round-trip — flags     | `raw_1mb_s256k`, `raw_1mb_noseek`, `raw_1mb_level1`, `raw_1mb_level22`                                                            | `-s`, `-j`, `-l` flag paths                                                                                                                                                      |
| Raw round-trip — large     | `raw_1gb`                                                                                                                         | 1 GB file (auto-skipped if disk < ~4 GB)                                                                                                                                         |
| Tar round-trip — single    | `tar_single`                                                                                                                      | basic tar mode                                                                                                                                                                   |
| Tar round-trip — multi     | `tar_multi`, `tar_multi_s512k`, `tar_big_S1M`, `tar_multi_sS`, `tar_multi_threads`                                                | multi-file archives, `-s`, `-S`, `-T`                                                                                                                                            |
| Tar round-trip — large     | `tar_500mb`                                                                                                                       | 500 MB tar (auto-skipped if disk < ~2 GB)                                                                                                                                        |
| Verbose mode               | `tar_single_v`, `raw_1mb_v`                                                                                                       | all `-v` logging paths in `compressFile()` and `writeSeekTable()`                                                                                                                |
| Edge cases                 | `empty_tar`, `tar_unaligned`                                                                                                      | zero-byte file in tar; file size not aligned to 512 bytes                                                                                                                        |
| Checksum format            | `err_git_archive_checksum`                                                                                                        | 7-digit header checksums, as `git archive` writes them                                                                                                                           |
| Tar sizes — 4 GiB and more | `err_ustar_size_over_4gib`, `err_base256_size`, `err_pax_size`                                                                    | sizes that do not fit in 32 bits: octal (4 to 8 GiB), base-256 and pax `size=` records (sparse members; skipped with less than 10 GB free)                                       |
| GNU sparse entries         | `err_gnu_sparse_extended`                                                                                                         | sparse map extension blocks after the header (needs GNU tar)                                                                                                                     |
| Tar framing                | `err_pax_header_own_frame`, `err_one_frame_per_file`, `err_maxblock_no_eoa`, `err_maxblock_null_blocks`, `err_partial_tail_block` | extended headers, AppleDouble files and end-of-archive blocks kept in the frame of a file; `-S` on archives with and without end-of-archive blocks; a partial last block refused |
| Large inputs               | `err_input_over_2gib`, `err_huge_member_seek_table`, `err_huge_raw_frame_seek_table`                                              | files of 2 GiB and more where `off_t` is 32 bits; frames kept below 2 GiB so that the seek table stays (skipped with too little disk space)                                      |

### Stdin / stdout (streaming path)

| Category                   | Tests                                                                                                    | What is covered                                                                                                                                       |
|----------------------------|----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| Stdin raw — baseline       | `stdin_raw_to_file`, `stdin_raw_to_stdout`                                                               | `compressStdinRaw()` single-frame streaming (pledged unknown)                                                                                         |
| Stdin raw — flags          | `stdin_raw_s256k`, `stdin_raw_noseek`, `stdin_raw_v`                                                     | `compressStdinRaw()` fixed-frame path (`-s`), skip seek table (`-j`), verbose                                                                         |
| Stdin tar — single file    | `stdin_tar_to_file`, `stdin_tar_S1M`, `stdin_tar_v`                                                      | `compressStdinTar()` baseline, maxBlockSize splitting (`-S`), verbose                                                                                 |
| Stdin tar — multi file     | `stdin_tar_multi`, `stdin_tar_multi_s512k`, `stdin_tar_multi_sS`                                         | multi-file tar from stdin, minBlockSize aggregation (`-s`), combined (`-s` + `-S`)                                                                    |
| Stdin → stdout (full pipe) | `stdin_tar_to_stdout`                                                                                    | stdin and stdout simultaneously in tar mode                                                                                                           |
| Stdin error paths          | `err_stdin_empty_raw`, `err_stdin_empty_tar_mode`, `err_stdin_default_stdout`, `err_stdin_file_stdout`   | empty stdin (raw: exit 0; tar: exit 1), default stdout fallback, explicit `-o -`                                                                      |
| Stdin streaming errors     | `err_stdin_corrupt_tar`, `err_stdin_empty_tar`, `err_stdin_truncated_tar`, `err_stdin_truncated_payload` | `isTarHeader()` failure via stdin, `isZeroTarBlock()` zero-block handling, truncated header (`r != 512`), `readExactStdin()` EOF on truncated payload |
| Stdout from file           | `err_stdout_tar_file`                                                                                    | mmap path with `-o -` (stdout output from file input, tar mode)                                                                                       |
| Explicit `-o -` + stdin    | `err_stdin_explicit_stdout_raw`, `err_stdin_explicit_stdout_tar`                                         | stdoutMode set via explicit `-o -` when input is also stdin, raw and tar modes                                                                        |
| Pipe input                 | `err_fifo_input`                                                                                         | a FIFO and `<(...)` streamed by `prepareInput()` (raw mode from the name), and `t2sz - < fifo` framed like the file                                   |
| Frame headers from stdin   | `err_stdin_frame_header`                                                                                 | without `-s`, frames from stdin carry their content size in the header, as from a file                                                                |
| Terminal stdout            | `err_stdout_terminal`                                                                                    | no archive written to a terminal unless `-o -` asks for it                                                                                            |

### CLI validation and error paths

| Category              | Tests                                                                                                                                      | What is covered                                                                                                                                                                          |
|-----------------------|--------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| CLI validation        | `err_no_args`, `err_too_many_args`, `err_bad_level_*`, `err_bad_block_*`, `err_bad_threads`, `err_block_S_lt_s`, `err_help`, `err_version` | all `usage()` and argument-check branches                                                                                                                                                |
| strtol edge cases     | `err_bad_level_strtol`, `err_bad_block_s_strtol`, `err_bad_block_S_strtol`, `err_bad_threads_strtol`                                       | `endptr == optarg`, `*endptr != '\0'` (trailing garbage), `ERANGE`, negative values, `val > UINT32_MAX`                                                                                  |
| Unknown option        | `err_unknown_option`                                                                                                                       | getopt `'?'` → `usage("ERROR: Unknown option")` → exit 1                                                                                                                                 |
| File-system errors    | `err_file_not_found`, `err_output_bad_path`, `err_empty_file`, `err_mmap_tiny_tar`                                                         | `access()` failure, `fopen()` failure in `prepareOutput()`, zero-byte input (an empty archive in raw mode, an error naming the file in tar mode), sub-512-byte file in tar mode          |
| Overwrite prompt      | `err_overwrite_no`, `err_overwrite_yes`                                                                                                    | prompt on a terminal (`script`): answer `n` (no overwrite), `y` or `Y` (overwrite), FIFO input                                                                                           |
| Prompt off a terminal | `err_prompt_eof`, `err_prompt_eats_loop_input`, `err_prompt_dev_stdin`                                                                     | no prompt unless stdin is a terminal: `-f` is required instead of an answer read from the data or from an end of file                                                                    |
| Stdin overwrite       | `err_stdin_overwrite_no_force`, `err_stdin_overwrite_force`                                                                                | stdinMode + existing file: error without `-f`, success with `-f` (no prompt read from the data)                                                                                          |
| Overflow guard        | `err_overflow_s`, `err_overflow_S`                                                                                                         | `(size_t)val > SIZE_MAX / multiplier` for `-s` and `-S` (huge value × large suffix)                                                                                                      |
| Corrupted input       | `err_corrupt_tar`                                                                                                                          | `isTarHeader()` checksum-mismatch path in mmap mode                                                                                                                                      |
| Auto raw-mode         | `err_auto_raw`, `err_tar_suffixes`                                                                                                         | `strEndsWith()`: a file not ending in `.tar` or `.gtar`, in any case, is compressed in raw mode                                                                                          |
| Default output name   | `err_auto_outname`                                                                                                                         | `getOutFilename()` called when `-o` is omitted                                                                                                                                           |
| Size suffixes         | `err_multiplier_suffixes`, `err_multiplier_suffixes_extra`, `err_garbage_suffix`                                                           | `decodeMultiplier()` all branches: `GiB`, `kB`, `KB`, `MB`, `GB`, `K`, `KiB`, `MiB`, `G`; garbage between number and suffix rejected                                                     |
| Block size in bytes   | `err_block_size_bytes_over_2gib`                                                                                                           | `-s` and `-S` of 2 GiB or more written in bytes (`strtoull()`)                                                                                                                           |
| Help text             | `err_help_program_name`                                                                                                                    | the program name in the usage line, without positional `printf` arguments (Windows)                                                                                                      |
| Output safety         | `err_output_is_input`, `err_failed_run_leaves_output`, `err_close_error_exit`, `err_closed_stderr`                                         | an output that is the input refused; no output left by a failed or interrupted run; write errors at close and on a closed stdout; messages kept out of the archive when stderr is closed |
| Special inputs        | `err_special_files`, `err_non_ascii_filename`                                                                                              | character devices, `/proc` files and directories; file names outside the ANSI code page on Windows                                                                                       |

### Seek table and structural verification

| Category                  | Tests                         | What is covered                                                                                                                                             |
|---------------------------|-------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Seek table on-disk        | all round-trip tests          | every round-trip verifies seek table magic, descriptor, Frame_Size and Number_Of_Frames on disk, and that the entries add up to the frames and to the input |
| No-seek-table (`-j`)      | `err_noseek_verify`           | verifies seekable magic `0x8F92EAB1` is absent when `-j` flag is used                                                                                       |
| `-j` in tar mode          | `err_noseek_tar`              | tar mode with `-j`, from a file and from stdin: exit 0 and a complete archive                                                                               |
| Non-multiple `-s` (mmap)  | `err_raw_nonmultiple_s`       | 1000001 bytes with `-s 256k`: partial last frame + seek table with 4 frames                                                                                 |
| Non-multiple `-s` (stdin) | `err_stdin_raw_nonmultiple_s` | same via stdin: `compressStdinRaw()` Path B partial last frame                                                                                              |
| Trailing junk after tar   | `err_trailing_junk_tar`       | 1024 bytes of 0xAA appended after end-of-archive: both mmap and stdin reject it with exit 1                                                                 |
| Non-regular tar entries   | `err_tar_with_dirs_symlinks`  | directory + symlink + regular file: round-trip + seek table structure verification                                                                          |
| Seek table capacity grow  | `err_seektable_grow`          | 1025×1k raw → 1025 frames, forces `seekTableEnsureCap()` realloc from 1024 to 2048 entries                                                                  |

Large tests (`raw_1gb`, `tar_500mb` and the multi-GiB ones on sparse files) return exit code 77 when disk space is insufficient; CTest treats this as a skip rather than a failure.

---

## Coverage results

Current numbers measured on macOS Apple Silicon (AppleClang 17, libzstd 1.5.x).
Re-run `tests/test_coverage.sh` after changes to get exact figures.

### What is not covered (and why)

The uncovered lines consist of defensive error-handling branches that cannot be
reached without hardware or environment conditions outside normal test execution:

- **Big-endian path in `writeLE32`** — x86-64 and ARM64 are always little-endian.
- **`prepareInput` I/O failures** — `open()` after a successful `access()` (TOCTOU race), or `dup2()` failing on a valid descriptor.
- **`prepareCctx` failures** — `ZSTD_createCCtx()` returning NULL requires memory exhaustion; parameter errors require a broken libzstd build.
- **`compressFile` fatal paths** — a `ZSTD_compressStream2` error requires a corrupt compression context.
- **`seekTableAdd` overflow guard** — triggered only by more than 134 million frames (frames stay below 2 GiB).
- **Multi-thread fallback** — requires libzstd built without `ZSTD_MULTITHREAD`.
- **`malloc` failure paths** — `newContext()`, `getOutFilename()`, `prepareOutput()`, `compressStdinRaw()` all have OOM guards that require memory exhaustion.
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

## Windows cross-compilation testing (Docker + Wine)

The Windows executables are built with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)
and tested under [Wine](https://www.winehq.org/) using the same CTest suite.
Docker provides a reproducible Linux environment for both macOS and Linux hosts.

Three scripts handle the cross-compilation workflow:

| Script                       | Purpose                                                                  |
|------------------------------|--------------------------------------------------------------------------|
| `windows/win-cross-setup.sh` | Shared setup: installs llvm-mingw and downloads zstd source (idempotent) |
| `windows/win-cross-build.sh` | Builds stripped Release executables for amd64, arm64, or both            |
| `windows/win-cross-test.sh`  | Builds Debug with tests + LLVM coverage, runs CTest via Wine             |

### Quick start

```bash
# Debug build + full CTest suite via Wine (amd64):
docker run --rm --platform linux/amd64 -v "$(pwd)":/src ubuntu:24.04 bash /src/windows/win-cross-test.sh

# Release build (both architectures):
docker run --rm -v "$(pwd)":/src ubuntu:24.04 bash /src/windows/win-cross-build.sh both
```

The test script will:

1. Install llvm-mingw and cross-compile zstd + t2sz for Windows
2. Build with `-DBUILD_TESTS=ON` and LLVM coverage instrumentation
3. Detect and verify Wine (graceful fallback to build-only if unavailable)
4. Replace `.exe` files with bash wrappers that invoke Wine transparently
5. Run all CTest tests through Wine
6. Generate an LLVM coverage report

### Build directories

| Directory                     | Contents                                                      |
|-------------------------------|---------------------------------------------------------------|
| `build-windows-amd64-debug`   | Debug build with tests + coverage (amd64)                     |
| `build-windows-arm64-debug`   | Debug build with tests (arm64, build-only — Wine unavailable) |
| `build-windows-amd64-release` | Stripped Release binary (amd64)                               |
| `build-windows-arm64-release` | Stripped Release binary (arm64)                               |

### Wine wrapper trick

CTest resolves `$<TARGET_FILE:t2sz>` to `t2sz.exe`.  On Linux, file extensions
are ignored — the kernel checks the shebang.  The test script renames the real
PE binary to `t2sz.real.exe` and creates a shell script at `t2sz.exe`:

```bash
#!/bin/bash
WINEDEBUG=-all exec wine64 "/path/to/t2sz.real.exe" "$@"
```

This makes all tests run through Wine with zero modifications to the test
scripts or CMakeLists.txt.

### Environment variables

| Variable           | Default                    | Description                                                  |
|--------------------|----------------------------|--------------------------------------------------------------|
| `SRC_DIR`          | parent of script directory | Path to the t2sz source tree                                 |
| `BUILD_BASE_DIR`   | `SRC_DIR`                  | Where `build-windows-*` directories are created              |
| `CTEST_JOBS`       | `4`                        | CTest parallelism level (reduce if Wine processes cause OOM) |
| `CTEST_EXTRA_ARGS` | *(empty)*                  | Extra flags passed to CTest (e.g. `--exclude-regex raw_1gb`) |

### Known limitations

- `raw_1gb` may timeout under Wine + coverage instrumentation (~10 min).
- arm64 Windows executables cannot be tested (Wine on arm64 Linux hangs).
- Coverage requires the amd64 platform (LLVM profiling runtime writes via Wine I/O).