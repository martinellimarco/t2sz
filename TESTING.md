# Testing

## Overview

The test suite exercises t2sz across three dimensions:

| Dimension | Tool | What it catches |
|-----------|------|-----------------|
| **Correctness** | round-trip + SHA-256 | compression/decompression produces bit-identical output |
| **Memory safety** | AddressSanitizer + UBSanitizer | buffer overflows, use-after-free, undefined behaviour |
| **Code coverage** | LLVM coverage + llvm-cov | dead or untested code paths |

36 tests in total: 18 round-trip tests and 18 CLI/error/edge-case tests.
All three build configurations run the same 36 tests.

---

## Prerequisites

| Dependency | Required for | macOS | Linux |
|------------|-------------|-------|-------|
| `cmake ≥ 3.16` | all builds | `brew install cmake` | `apt install cmake` |
| `libzstd-dev` | all builds | `brew install zstd` | `apt install libzstd-dev` |
| `zstd` CLI | round-trip tests | included with `brew install zstd` | `apt install zstd` |
| LLVM (`llvm-cov`, `llvm-profdata`) | coverage report only | `brew install llvm` | `apt install llvm` |

---

## Quick start

```bash
cmake -B build -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cd build && ctest --output-on-failure
```

Expected output: `100% tests passed, 0 tests failed out of 36`

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

| Category | Tests | What is covered |
|----------|-------|-----------------|
| Raw round-trip — baseline | `raw_1mb`, `raw_100mb` | basic `-r` compression + SHA-256 verification |
| Raw round-trip — flags | `raw_1mb_s256k`, `raw_1mb_noseek`, `raw_1mb_level1`, `raw_1mb_level22` | `-s`, `-j`, `-l` flag paths |
| Raw round-trip — large | `raw_1gb` | 1 GB file (auto-skipped if disk < 5 GB) |
| Tar round-trip — single | `tar_single` | basic tar mode |
| Tar round-trip — multi | `tar_multi`, `tar_multi_s512k`, `tar_big_S1M`, `tar_multi_sS`, `tar_multi_threads` | multi-file archives, `-s`, `-S`, `-T` |
| Tar round-trip — large | `tar_500mb` | 500 MB tar (auto-skipped if disk < 5 GB) |
| Verbose mode | `tar_single_v`, `raw_1mb_v` | all `-v` logging paths in `compressFile()` and `writeSeekTable()` |
| Edge cases | `empty_tar`, `tar_unaligned` | zero-byte file in tar; file size not aligned to 512 bytes |
| CLI validation | `err_no_args`, `err_too_many_args`, `err_bad_level_*`, `err_bad_block_*`, `err_bad_threads`, `err_block_S_lt_s`, `err_help`, `err_version` | all `usage()` and argument-check branches |
| File-system errors | `err_file_not_found`, `err_output_bad_path` | `access()` failure, `fopen()` failure in `prepareOutput()` |
| Overwrite prompt | `err_overwrite_no`, `err_overwrite_yes` | `scanf` branch: answer `n` (no overwrite) and `y` (overwrite) |
| Corrupted input | `err_corrupt_tar` | `isTarHeader()` checksum-mismatch path → `exit(-1)` |
| Auto raw-mode | `err_auto_raw` | `strEndsWith()` branch: non-`.tar` file treated as raw automatically |
| Default output name | `err_auto_outname` | `getOutFilename()` called when `-o` is omitted |
| Size suffixes | `err_multiplier_suffixes` | `decodeMultiplier()` branches for `GiB`, `kB`, `KB`, `MB`, `GB` |

Large tests (`raw_1gb`, `tar_500mb`) return exit code 77 when disk space is insufficient; CTest treats this as a skip rather than a failure.

---

## Coverage results

Current numbers measured on macOS Apple Silicon (AppleClang 17, libzstd 1.5.x):

| Metric | Coverage |
|--------|----------|
| Functions | **100%** (18 / 18) |
| Lines | **91%** (395 / 434) |
| Regions | **91%** |
| Branches | **89%** |

### Why not 100% lines?

The remaining 9% consists of error-handling branches that cannot be reached
without hardware or environment conditions outside normal test execution:

- **Big-endian path in `writeLE32`** — x86 and ARM are always little-endian.
- **`prepareInput` failures** — `open()` after a successful `access()` (TOCTOU race); `mmap()` failure requires OS-level fault injection.
- **`prepareCctx` failures** — `ZSTD_createCCtx()` returning NULL requires memory exhaustion; parameter errors require a broken libzstd build.
- **`compressFile` fatal paths** — "This is a bug" branch is structurally unreachable; `ZSTD_compressStream2` error requires a corrupt compression context.
- **`seekTableAdd` overflow guards** — triggered only by > 134 million frames or a single block > 2 GB.
- **Multi-thread fallback** — requires libzstd built without `ZSTD_MULTITHREAD`.

These are defensive guards, not untested logic.
