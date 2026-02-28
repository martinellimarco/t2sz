# Fuzzing

## Overview

The `fuzz/` directory contains [libFuzzer](https://llvm.org/docs/LibFuzzer.html)
harnesses for fuzz-testing t2sz. Fuzzing complements the deterministic test
suite (76 tests) by exploring the vast space of possible inputs that manual
tests cannot cover.

Three harnesses are provided:

| Harness          | Code path             | What it exercises                                                                                                                                   |
|------------------|-----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
| `fuzz_tar_mmap`  | mmap tar (file input) | `isTarHeader()`, `checksum()`, `strtoul(header->size)`, the `tarHeaderIdx` state machine in `compressFile()`, `maxBlockSize` / `residual` splitting |
| `fuzz_tar_stdin` | stdin tar (streaming) | `compressStdinTar()`, `readExactStdin()`, `pushBytesTar()`, `isZeroTarBlock()`, truncated header/payload handling                                   |
| `fuzz_cli`       | CLI arg parsing       | `parseArgs()`, `decodeMultiplier()`, `strtol()` edge cases, getopt option handling, suffix validation, stdin/raw mode detection                     |

The two tar harnesses include a **checksum-aware custom mutator** that
recalculates the tar header checksum after each mutation. Without it, the
fuzzer would waste >99.99% of iterations on checksum failures (probability of
a valid random checksum: ~1 in 2^48).

The CLI harness does not need a custom mutator — default libFuzzer mutations
work well on short null-delimited ASCII strings.

---

## Prerequisites

| Dependency    | Required                            | Install                                                      |
|---------------|-------------------------------------|--------------------------------------------------------------|
| Clang         | yes (libFuzzer is built into clang) | macOS: `brew install llvm`; Linux: `apt install clang`       |
| libzstd-dev   | yes                                 | macOS: `brew install zstd`; Linux: `apt install libzstd-dev` |
| cmake >= 3.16 | yes                                 | macOS: `brew install cmake`; Linux: `apt install cmake`      |
| python3       | for seed corpus only                | pre-installed on most systems                                |

> **macOS note**: AppleClang (shipped with Xcode) does **not** include the
> libFuzzer runtime. You must use Homebrew LLVM clang instead. The build
> system automatically detects macOS and handles two platform-specific
> compatibility issues:
> 1. Links against Homebrew LLVM's libc++ (Apple's system libc++ is missing
>    symbols used by the libFuzzer runtime).
> 2. Excludes the `vptr` and `function` UBSAN checks, which generate
>    relocations incompatible with Apple's system linker on large translation
>    units. All other UBSAN checks (signed/unsigned overflow, shift, null,
>    alignment, etc.) remain active.

---

## Quick start

```bash
# Build the fuzz harnesses
# Linux:
CC=clang cmake -B build_fuzz -DFUZZ=ON
cmake --build build_fuzz

# macOS (Homebrew LLVM):
CC=/opt/homebrew/opt/llvm/bin/clang cmake -B build_fuzz -DFUZZ=ON
cmake --build build_fuzz

# Generate the seed corpus (10 files per harness)
cmake --build build_fuzz --target fuzz_corpus

# Run the mmap harness (most important target)
cd build_fuzz/fuzz
./fuzz_tar_mmap corpus_mmap/ -max_len=65536 -timeout=10 -detect_leaks=0

# Run the stdin harness
./fuzz_tar_stdin corpus_stdin/ -max_len=65536 -timeout=10 -detect_leaks=0

# Run the CLI harness
./fuzz_cli corpus_cli/ -max_len=4096 -timeout=5 -detect_leaks=0
```

For multi-core fuzzing:

```bash
./fuzz_tar_mmap corpus_mmap/ -max_len=65536 -timeout=10 -detect_leaks=0 -jobs=4 -workers=4
```

---

## Recommended flags

| Flag                 | Value     | Why                                                                                          |
|----------------------|-----------|----------------------------------------------------------------------------------------------|
| `-max_len`           | `65536`   | 64 KiB is enough for multi-header tar archives; larger inputs waste cycles on compression    |
| `-timeout`           | `10`      | Kills iterations that hang (e.g., a crafted size field causes excessive reads)               |
| `-detect_leaks`      | `0`       | Disables LeakSanitizer; the `setjmp`/`longjmp` exit override inherently leaks on error paths |
| `-rss_limit_mb`      | `4096`    | Caps RSS to 4 GiB; prevents OOM on inputs with huge tar size fields                          |
| `-jobs` / `-workers` | CPU cores | Parallel fuzzing across multiple processes                                                   |

---

## Reproducing and minimizing crashes

```bash
# Reproduce a crash
./fuzz_tar_mmap crash-XXXXXXX

# Minimize the crash input to the smallest reproducer
./fuzz_tar_mmap -minimize_crash=1 -exact_artifact_path=minimized.bin crash-XXXXXXX
```

---

## Converting a crash to a deterministic test

When the fuzzer finds a crash, the recommended workflow is:

1. Minimize the crash input (see above).
2. Copy the minimized file into `tests/` (e.g., `tests/crash_mmap_001.bin`).
3. Add a new test case in `tests/test_error_paths.sh` that feeds the crash
   file to t2sz and asserts the expected behavior (non-zero exit, no crash).
4. Register the test in `tests/CMakeLists.txt` and update `TESTING.md`.
5. Fix the bug in `src/t2sz.c`.
6. Verify: the crash reproducer now passes, and all 76+ tests still pass.

This ensures the bug never regresses.

---

## Architecture

### Why `#include "../src/t2sz.c"` ?

t2sz is a monolithic single-file program. Rather than refactoring it into a
library + main, the harnesses include the source directly with
`-DT2SZ_NO_MAIN` to exclude `main()`. This gives full access to all `static`
functions (e.g., `compressStdinTar`, `pushBytesTar`, `isZeroTarBlock`,
`parseArgs`) without any code changes beyond a 2-line `#ifndef` guard. This
is a standard pattern used by OSS-Fuzz projects (cJSON, miniz, etc.).

The CLI argument parsing logic lives in `parseArgs()`, which is defined
**outside** the `#ifndef T2SZ_NO_MAIN` guard so it is accessible to both
`main()` and the `fuzz_cli` harness.

### Why `setjmp`/`longjmp` for `exit()` ?

t2sz calls `exit(EXIT_FAILURE)` on parse errors and fatal conditions. Inside
a libFuzzer harness, `exit()` would kill the fuzzer process. The harnesses
override `exit()` to `longjmp` back to a recovery point, allowing cleanup
and the next iteration. This is a well-established fuzzing technique.

Resources leaked by the interrupted code path (e.g., `chunkBuf` inside
`compressStdinTar`) are harmless — they are tiny and the fuzzer runs with
`-detect_leaks=0`.

### Why a custom mutator ?

The tar header checksum is a simple unsigned sum of all 512 bytes (with the
checksum field treated as spaces). Random byte mutations almost never produce
a valid checksum. The custom mutator calls `LLVMFuzzerMutate()` first (default
mutations), then recalculates and patches the checksum in every non-null
512-byte block. This lets the fuzzer explore the code paths **after** checksum
validation, where the interesting bugs live.

---

## Build options

The `-DFUZZ=ON` option is mutually exclusive with `-DSANITIZE=ON` and
`-DCOVERAGE=ON` because the fuzz build includes its own ASAN + UBSAN
instrumentation via `-fsanitize=fuzzer,address,undefined`.

On macOS, the build automatically adjusts to
`-fsanitize=fuzzer,address,undefined -fno-sanitize=vptr,function` to avoid
linker incompatibilities with Apple's `ld`. All C-relevant UBSAN checks remain
active; only the C++-specific `vptr` and `function` checks are excluded.

The normal build (`-DBUILD_TESTS=ON`) is not affected by the `T2SZ_NO_MAIN`
guard — it is only active when `-DT2SZ_NO_MAIN` is passed at compile time.
