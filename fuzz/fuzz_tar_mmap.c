// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * fuzz_tar_mmap — libFuzzer harness for the mmap tar-parsing code path.
 *
 * Exercises compressFile() in tar mode with a memory-mapped input buffer
 * pointing directly at the fuzzer's data. Output is discarded to /dev/null.
 *
 * A custom mutator recalculates tar header checksums after each mutation,
 * allowing the fuzzer to efficiently explore code paths past the checksum
 * validation gate in isTarHeader().
 *
 * Build:  CC=clang cmake -B build_fuzz -DFUZZ=ON && cmake --build build_fuzz
 * Run:    ./build_fuzz/fuzz/fuzz_tar_mmap corpus_mmap/ -max_len=65536 -timeout=10
 */

/* T2SZ_NO_MAIN and VERSION are provided via -D flags in CMakeLists.txt. */
#include "../src/t2sz.c"

#include <setjmp.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>

/* libFuzzer provides this symbol at link time; declare it for the compiler. */
extern size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size);

/* ── setjmp/longjmp trap for exit() ─────────────────────────────────────────
 *
 * compressFile() calls exit(EXIT_FAILURE) on parse errors and compression
 * failures. In a normal process this is fine, but inside a libFuzzer harness
 * it would kill the fuzzer. We override exit() to longjmp back to the
 * harness's recovery point, allowing cleanup and the next iteration.
 *
 * Leaks from interrupted code paths are expected and harmless — run with
 * -detect_leaks=0 to suppress LSAN noise.
 */
static jmp_buf fuzz_jmp;
static volatile int fuzz_active = 0;

void exit(int status) {
    if (fuzz_active)
        longjmp(fuzz_jmp, status ? status : 1);
    _exit(status);
}

/* ── Custom mutator: checksum-aware tar header repair ───────────────────────
 *
 * Without this, the probability of a random mutation producing a valid tar
 * checksum is approximately 1 in 2^48. The mutator lets libFuzzer's default
 * mutation engine do its work, then recalculates and patches the checksum
 * field in every non-null 512-byte block, so the fuzzer can focus on
 * exercising interesting field values (size, typeflag, name, etc.) rather
 * than wasting cycles on checksum failures.
 */
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
    /* Let libFuzzer mutate first. */
    size_t new_size = LLVMFuzzerMutate(data, size, max_size);

    /* Fix up checksums in every 512-byte-aligned block that has a non-zero
     * first byte (null blocks are end-of-archive markers, not headers). */
    for (size_t off = 0; off + 512 <= new_size; off += 512) {
        if (data[off] != 0)
            fix_tar_checksum(data + off, 512);
    }
    return new_size;
}

/* ── Harness entry point ────────────────────────────────────────────────────*/

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* A tar header is 512 bytes; anything smaller cannot reach the parser. */
    if (size < 512) return 0;

    /* Suppress stderr noise from t2sz error messages. */
    int saved_stderr = dup(STDERR_FILENO);
    int devnull_err = open("/dev/null", O_WRONLY);
    if (devnull_err >= 0) {
        dup2(devnull_err, STDERR_FILENO);
        close(devnull_err);
    }

    /* Build a Context that mimics the mmap tar path. */
    Context *ctx = newContext();
    ctx->rawMode    = false;
    ctx->stdinMode  = false;
    ctx->stdoutMode = true;   /* write compressed output to stdout */
    ctx->level      = 1;      /* fastest compression level */
    ctx->verbose    = false;

    /* Point the input buffer directly at the fuzzer's data (read-only). */
    ctx->inBuff     = (uint8_t *)data;
    ctx->inBuffSize = size;

    /* Redirect stdout to /dev/null so compressed output is discarded. */
    int saved_stdout = dup(STDOUT_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDOUT_FILENO);
        close(devnull);
    }

    /* Run the full mmap tar compression pipeline.
     * compressFile() internally calls prepareOutput() and prepareCctx(),
     * so we do NOT call them here (that would leak the first allocation).
     * If exit() is called (parse error, compression error), the longjmp
     * brings us back here with jumped != 0. */
    fuzz_active = 1;
    int jumped = setjmp(fuzz_jmp);
    if (jumped == 0) {
        compressFile(ctx);
    }
    fuzz_active = 0;

    /* Restore stdout and stderr. */
    if (saved_stdout >= 0) {
        dup2(saved_stdout, STDOUT_FILENO);
        close(saved_stdout);
    }
    if (saved_stderr >= 0) {
        dup2(saved_stderr, STDERR_FILENO);
        close(saved_stderr);
    }

    /* Cleanup — must handle partial state from interrupted exit(). */
    if (ctx->cctx)    ZSTD_freeCCtx(ctx->cctx);
    if (ctx->outBuff) free(ctx->outBuff);
    if (ctx->seekTable) free(ctx->seekTable);
    if (ctx->outFile && ctx->outFile != stdout) fclose(ctx->outFile);
    free(ctx);

    return 0;
}
