// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * fuzz_tar_stdin — libFuzzer harness for the stdin tar-parsing code path.
 *
 * Exercises compressStdinTar() by replacing stdin with a memory-backed FILE*
 * (fmemopen) pointing at the fuzzer's data. Output is discarded to /dev/null.
 *
 * A custom mutator recalculates tar header checksums after each mutation,
 * allowing the fuzzer to efficiently explore code paths past the checksum
 * validation gate in isTarHeader().
 *
 * Build:  CC=clang cmake -B build_fuzz -DFUZZ=ON && cmake --build build_fuzz
 * Run:    ./build_fuzz/fuzz/fuzz_tar_stdin corpus_stdin/ -max_len=65536 -timeout=10
 */

/* T2SZ_NO_MAIN and VERSION are provided via -D flags in CMakeLists.txt. */
#include "../src/t2sz.c"

#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <dlfcn.h>

/* libFuzzer provides this symbol at link time; declare it for the compiler. */
extern size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size);

/* ── setjmp/longjmp trap for exit() ─────────────────────────────────────────
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

/* ── Custom mutator: checksum-aware tar header repair ───────────────────────*/
static void fix_tar_checksum(uint8_t *data, size_t size) {
    if (size < 512) return;
    uint32_t ac = 0;
    for (size_t i = 0; i < 512; i++) {
        ac += (i >= 148 && i < 156) ? 0x20 : data[i];
    }
    char buf[8];
    snprintf(buf, sizeof(buf), "%06o", ac);
    buf[6] = '\0';
    buf[7] = ' ';
    memcpy(data + 148, buf, 8);
}

size_t LLVMFuzzerCustomMutator(uint8_t *data, size_t size,
                                size_t max_size, unsigned int seed) {
    size_t new_size = LLVMFuzzerMutate(data, size, max_size);
    /* Full 512-byte zero check, matching the parser's isZeroTarBlock(). */
    for (size_t off = 0; off + 512 <= new_size; off += 512) {
        bool allZero = true;
        for (size_t i = 0; i < 512; i++) {
            if (data[off + i] != 0) { allZero = false; break; }
        }
        if (!allZero)
            fix_tar_checksum(data + off, 512);
    }
    return new_size;
}

/* ── Harness entry point ────────────────────────────────────────────────────*/

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0) return 0;

    /* Replace stdin with a memory-backed FILE* containing the fuzz input.
     * fmemopen() is POSIX.1-2008, available on Linux and macOS 10.13+. */
    FILE *mem = fmemopen((void *)data, size, "rb");
    if (!mem) return 0;
    FILE *saved_stdin = stdin;
    stdin = mem;

    /* Suppress stderr noise. */
    int saved_stderr = dup(STDERR_FILENO);
    int devnull_err = open("/dev/null", O_WRONLY);
    if (devnull_err >= 0) {
        dup2(devnull_err, STDERR_FILENO);
        close(devnull_err);
    }

    /* Redirect stdout to /dev/null. */
    int saved_stdout = dup(STDOUT_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDOUT_FILENO);
        close(devnull);
    }

    /* Build a Context for the stdin tar path.
     * fuzz_active is set BEFORE newContext() so that even an OOM inside
     * newContext() is caught by longjmp rather than killing the process. */
    /* volatile: ctx is modified between setjmp and longjmp.  Without
     * volatile the compiler may keep it in a register that longjmp
     * restores to its pre-setjmp value (NULL), skipping all cleanup. */
    Context * volatile ctx = NULL;

    fuzz_active = 1;
    int jumped = setjmp(fuzz_jmp);
    if (jumped == 0) {
        ctx = newContext();
        ctx->rawMode    = false;
        ctx->stdinMode  = true;
        ctx->stdoutMode = true;
        ctx->level      = 1;
        ctx->verbose    = false;

        prepareOutput(ctx);
        prepareCctx(ctx);
        compressStdinTar(ctx);
        /* Normal completion: write seek table and clean up. */
        if (!ctx->skipSeekTable)
            writeSeekTable(ctx);
        if (ctx->cctx) ZSTD_freeCCtx(ctx->cctx);
        ctx->cctx = NULL;
        free(ctx->outBuff);
        ctx->outBuff = NULL;
    }
    fuzz_active = 0;

    /* Restore stdin, stdout, stderr. */
    stdin = saved_stdin;
    fclose(mem);

    if (saved_stdout >= 0) {
        dup2(saved_stdout, STDOUT_FILENO);
        close(saved_stdout);
    }
    if (saved_stderr >= 0) {
        dup2(saved_stderr, STDERR_FILENO);
        close(saved_stderr);
    }

    /* Cleanup — handle partial state from interrupted exit().
     * ctx may be NULL if newContext() triggered longjmp. */
    if (ctx) {
        if (ctx->cctx)    ZSTD_freeCCtx(ctx->cctx);
        if (ctx->outBuff) free(ctx->outBuff);
        if (ctx->seekTable) free(ctx->seekTable);
        if (ctx->outFile && ctx->outFile != stdout) fclose(ctx->outFile);
        free(ctx);
    }

    return 0;
}
