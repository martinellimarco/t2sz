/*
 * gen_blob.c — Deterministic binary blob generator
 *
 * Usage: gen_blob <seed> <size_bytes> <output_file>
 *
 * Given the same seed and size, always produces identical output.
 * Uses xorshift64, a fast PRNG with good statistical distribution.
 * seed=0 is remapped to 1 (xorshift64 must not start at zero).
 *
 * Exit 0 on success, 1 on error.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* xorshift64: period 2^64-1, passes BigCrush */
static uint64_t xorshift64(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return (*state = x);
}

int main(const int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s <seed> <size_bytes> <output_file>\n", argv[0]);
        return 1;
    }

    uint64_t seed  = strtoull(argv[1], NULL, 10);
    const uint64_t total = strtoull(argv[2], NULL, 10);
    const char *path  = argv[3];

    if (seed == 0) {
        seed = 1; /* xorshift64 state must not be 0 */
    }

    FILE *f = fopen(path, "wb");
    if (!f) {
        fprintf(stderr, "gen_blob: cannot open '%s': %s\n", path, strerror(errno));
        return 1;
    }

    uint64_t state   = seed;
    uint64_t written = 0;

    /* Write full 8-byte words */
    while (written + 8 <= total) {
        uint64_t val = xorshift64(&state);
        if (fwrite(&val, 8, 1, f) != 1) {
            fprintf(stderr, "gen_blob: write error: %s\n", strerror(errno));
            fclose(f);
            return 1;
        }
        written += 8;
    }

    /* Write any remaining bytes (0-7) */
    if (written < total) {
        const uint64_t val = xorshift64(&state);
        const size_t rem = total - written;
        if (fwrite(&val, 1, rem, f) != rem) {
            fprintf(stderr, "gen_blob: write error: %s\n", strerror(errno));
            fclose(f);
            return 1;
        }
    }

    if (fclose(f) != 0) {
        fprintf(stderr, "gen_blob: close error: %s\n", strerror(errno));
        return 1;
    }

    return 0;
}
