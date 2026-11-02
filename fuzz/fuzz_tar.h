// SPDX-License-Identifier: GPL-3.0-or-later
/**
 * Code shared by the tar harnesses.
 *
 * fuzzSetMode() picks the -s, -S and -r settings to fuzz from the number of
 * 512-byte blocks in the input, so that every mode is fuzzed without
 * spending input bytes on it and without moving the tar headers that the
 * checksum-fixing mutator relies on. The sizes are not multiples of 512,
 * so frames also end inside tar blocks.
 *
 * Include after t2sz.c (it uses Context).
 */
#ifndef FUZZ_TAR_H
#define FUZZ_TAR_H

static const struct {
    size_t minBlockSize; /* -s */
    size_t maxBlockSize; /* -S */
    bool rawMode;        /* -r */
} FUZZ_MODES[] = {
    {    0,    0, false }, /* one entry per frame */
    { 2000,    0, false }, /* entries joined up to 2000 bytes */
    {    0, 1000, false }, /* entries split every 1000 bytes */
    { 1000, 1000, false }, /* frames of exactly 1000 bytes */
    {    0,    0, true  }, /* raw: the whole input */
    {  700,    0, true  }, /* raw: blocks of 700 bytes */
};

/* Set -s, -S and -r on ctx for an input of `size` bytes. */
static void fuzzSetMode(Context *ctx, const size_t size){
    const size_t m = (size / 512) % (sizeof(FUZZ_MODES) / sizeof(FUZZ_MODES[0]));
    ctx->minBlockSize = FUZZ_MODES[m].minBlockSize;
    ctx->maxBlockSize = FUZZ_MODES[m].maxBlockSize;
    ctx->rawMode      = FUZZ_MODES[m].rawMode;
}

#endif /* FUZZ_TAR_H */
