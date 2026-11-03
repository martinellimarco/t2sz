// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * fuzz_tar_stdin — libFuzzer harness for the stdin tar-parsing code path.
 *
 * Exercises compressStdinTar(), and compressStdinRaw() in raw mode, with the
 * -s and -S settings of fuzz_tar.h, by replacing stdin with a memory-backed
 * FILE* (fmemopen) pointing at the fuzzer's data. The output, kept in
 * memory, must decompress to the input whenever the run does not fail.
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
#include "fuzz_tar.h"

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

    /* Silence t2sz's messages through the stderr FILE, not file descriptor
     * 2: the sanitizers and libFuzzer write their reports there. */
    FILE *saved_stderr = stderr;
    stderr = fopen("/dev/null", "w");
    if (!stderr) abort();

    /* Collect the compressed output in memory, written through stdout. */
    char *out = NULL;
    size_t outLen = 0;
    FILE *outMem = open_memstream(&out, &outLen);
    if (!outMem) abort();
    FILE *saved_stdout = stdout;
    stdout = outMem;

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
        fuzzSetMode(ctx, size);
        ctx->stdinMode  = true;
        ctx->stdoutMode = true;
        ctx->level      = 1;
        ctx->verbose    = false;

        prepareOutput(ctx);
        prepareCctx(ctx);
        if (ctx->rawMode)
            compressStdinRaw(ctx);
        else
            compressStdinTar(ctx);
        /* Normal completion: write the seek table, flush and clean up. */
        cleanupCompression(ctx);
    }
    fuzz_active = 0;

    stdin = saved_stdin;
    fclose(mem);
    /* Messages buffered by a longjmp-interrupted run go to /dev/null. */
    fclose(stderr);
    stderr = saved_stderr;

    /* After a run that did not fail. */
    if (jumped == 0)
        fuzzCheckRoundTrip(data, size, out, outLen);
    stdout = saved_stdout;
    fclose(outMem);
    free(out);

    /* Cleanup — handle partial state from interrupted exit().
     * ctx may be NULL if newContext() triggered longjmp. */
    if (ctx) {
        if (ctx->cctx)    ZSTD_freeCCtx(ctx->cctx);
        if (ctx->outBuff) free(ctx->outBuff);
        if (ctx->seekTable) free(ctx->seekTable);
        free(ctx);
    }

    return 0;
}
