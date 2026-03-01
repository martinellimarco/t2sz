// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * fuzz_cli — libFuzzer harness for command-line argument parsing.
 *
 * Exercises parseArgs() with arbitrary option strings, covering:
 *   - getopt parsing (all flags: -l, -s, -S, -T, -o, -r, -j, -v, -f, -V, -h)
 *   - decodeMultiplier() suffix handling (k, K, KiB, M, MiB, G, GiB, kB, KB, MB, GB)
 *   - strtol() edge cases (overflow, underflow, non-numeric, empty)
 *   - Argument count validation (too few, too many)
 *   - maxBlockSize vs minBlockSize constraint
 *   - stdin mode detection ("-" as filename)
 *   - Raw mode auto-detection (.tar suffix)
 *
 * The fuzzer input is treated as a sequence of null-delimited strings that
 * become argv entries. No file I/O occurs — parseArgs() only populates the
 * Context struct.
 *
 * Build:  CC=clang cmake -B build_fuzz -DFUZZ=ON && cmake --build build_fuzz
 * Run:    ./build_fuzz/fuzz/fuzz_cli corpus_cli/ -max_len=4096 -timeout=5
 */

/* T2SZ_NO_MAIN and VERSION are provided via -D flags in CMakeLists.txt. */
#include "../src/t2sz.c"

#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <getopt.h>
#include <dlfcn.h>

/* ── setjmp/longjmp trap for exit() ─────────────────────────────────────────
 *
 * parseArgs() calls usage() on invalid arguments, which calls exit().
 * The -V flag calls version() then exit(). We catch all of these via
 * longjmp so the fuzzer survives and proceeds to the next iteration.
 *
 * We resolve the real libc exit() via dlsym(RTLD_NEXT) so that when
 * fuzz_active is false (e.g. libFuzzer shutdown), atexit handlers and
 * stdio buffers are flushed properly — preserving the summary report.
 */
static jmp_buf fuzz_jmp;
static volatile int fuzz_active = 0;

static void (*real_exit)(int);

__attribute__((constructor))
static void init_real_exit(void) {
    real_exit = (void (*)(int))dlsym(RTLD_NEXT, "exit");
}

void exit(int status) {
    if (fuzz_active)
        longjmp(fuzz_jmp, status ? status : 1);
    if (real_exit)
        real_exit(status);
    _exit(status);
}

/* ── Harness entry point ────────────────────────────────────────────────────
 *
 * Input format: raw bytes are split on '\0' to form argv entries.
 * argv[0] is always "t2sz" (fixed); the remaining strings come from the
 * fuzzer data. This naturally produces combinations like:
 *   "t2sz" "-l" "5" "-s" "10M" "file.tar"
 */

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Limit input: CLI args are short; very large inputs waste cycles. */
    if (size == 0 || size > 4096) return 0;

    /* Copy data so we can null-terminate safely. */
    char *copy = (char *)malloc(size + 1);
    if (!copy) return 0;
    memcpy(copy, data, size);
    copy[size] = '\0';

    /* Count how many strings the fuzzer produced (split on '\0').
     * Reserve space for argv[0] = "t2sz" plus a NULL terminator. */
    int argc = 1;  /* argv[0] = "t2sz" */
    for (size_t i = 0; i < size; i++) {
        if (copy[i] == '\0') argc++;
    }
    /* Cap argc to a reasonable maximum to avoid huge allocations. */
    if (argc > 64) {
        free(copy);
        return 0;
    }

    char **argv = (char **)malloc((argc + 1) * sizeof(char *));
    if (!argv) {
        free(copy);
        return 0;
    }
    argv[0] = (char *)"t2sz";
    int idx = 1;
    char *p = copy;
    char *end = copy + size;
    while (p < end && idx < argc) {
        argv[idx++] = p;
        p += strlen(p) + 1;
    }
    argc = idx;
    argv[argc] = NULL;

    /* Reset getopt state so it re-parses from the beginning. */
    optind = 1;
    opterr = 0;  /* suppress getopt's own error messages */
#ifdef __APPLE__
    optreset = 1;  /* BSD getopt requires this to reinitialize */
#endif

    /* Suppress stderr noise from usage() / version() / error messages. */
    int saved_stderr = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDERR_FILENO);
        close(devnull);
    }

    /* Also suppress stdout for version() / usage() output. */
    int saved_stdout = dup(STDOUT_FILENO);
    int devnull2 = open("/dev/null", O_WRONLY);
    if (devnull2 >= 0) {
        dup2(devnull2, STDOUT_FILENO);
        close(devnull2);
    }

    /* Call parseArgs() — exit() calls are caught by longjmp.
     * fuzz_active is set BEFORE newContext() so that even an OOM inside
     * newContext() is caught by longjmp rather than killing the process. */
    Context *ctx = NULL;
    bool overwrite = false;

    fuzz_active = 1;
    int jumped = setjmp(fuzz_jmp);
    if (jumped == 0) {
        ctx = newContext();
        parseArgs(argc, argv, ctx, &overwrite);
    }
    fuzz_active = 0;

    /* Restore stderr and stdout. */
    if (saved_stdout >= 0) {
        dup2(saved_stdout, STDOUT_FILENO);
        close(saved_stdout);
    }
    if (saved_stderr >= 0) {
        dup2(saved_stderr, STDERR_FILENO);
        close(saved_stderr);
    }

    /* Cleanup — ctx may be NULL if newContext() triggered longjmp. */
    free(ctx);
    free(argv);
    free(copy);

    return 0;
}
