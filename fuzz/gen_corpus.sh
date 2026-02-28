#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# gen_corpus.sh — Generate seed corpus files for the t2sz fuzz harnesses.
#
# Usage: gen_corpus.sh CORPUS_MMAP_DIR CORPUS_STDIN_DIR CORPUS_CLI_DIR
#
# The tar directories receive the same set of seeds (the mmap and stdin
# harnesses parse the same binary format; having identical seeds is correct).
# The CLI directory receives null-delimited argument strings for fuzz_cli.

set -euo pipefail

MMAP_DIR="$1"
STDIN_DIR="$2"
CLI_DIR="${3:-}"

mkdir -p "$MMAP_DIR" "$STDIN_DIR"
[ -n "$CLI_DIR" ] && mkdir -p "$CLI_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── Helper: copy seed to both corpus directories ────────────────────────────
install_seed() {
    local name="$1" src="$2"
    cp "$src" "$MMAP_DIR/$name"
    cp "$src" "$STDIN_DIR/$name"
}

# ── 1. minimal.tar — valid tar with one small file ─────────────────────────
printf 'hello fuzz\n' > "$WORK/hello.txt"
COPYFILE_DISABLE=1 tar cf "$WORK/minimal.tar" -C "$WORK" hello.txt 2>/dev/null
install_seed "minimal.tar" "$WORK/minimal.tar"

# ── 2. multi.tar — valid tar with 3 files of different sizes ───────────────
printf 'a' > "$WORK/tiny.txt"
dd if=/dev/urandom of="$WORK/medium.bin" bs=1 count=1000 2>/dev/null
dd if=/dev/urandom of="$WORK/larger.bin" bs=1 count=4096 2>/dev/null
COPYFILE_DISABLE=1 tar cf "$WORK/multi.tar" -C "$WORK" tiny.txt medium.bin larger.bin 2>/dev/null
install_seed "multi.tar" "$WORK/multi.tar"

# ── 3. empty_file.tar — valid tar containing a zero-byte file ──────────────
touch "$WORK/empty"
COPYFILE_DISABLE=1 tar cf "$WORK/empty_file.tar" -C "$WORK" empty 2>/dev/null
install_seed "empty_file.tar" "$WORK/empty_file.tar"

# ── 4. unaligned.tar — file size not aligned to 512 (triggers padding) ─────
dd if=/dev/urandom of="$WORK/unaligned.bin" bs=1 count=1000 2>/dev/null
COPYFILE_DISABLE=1 tar cf "$WORK/unaligned.tar" -C "$WORK" unaligned.bin 2>/dev/null
install_seed "unaligned.tar" "$WORK/unaligned.tar"

# ── 5. two_nulls.bin — 1024 zero bytes (standard end-of-archive) ──────────
dd if=/dev/zero of="$WORK/two_nulls.bin" bs=512 count=2 2>/dev/null
install_seed "two_nulls.bin" "$WORK/two_nulls.bin"

# ── 6. one_null.bin — 512 zero bytes (single null block) ──────────────────
dd if=/dev/zero of="$WORK/one_null.bin" bs=512 count=1 2>/dev/null
install_seed "one_null.bin" "$WORK/one_null.bin"

# ── 7. bad_checksum.bin — valid tar header with corrupted checksum ─────────
cp "$WORK/minimal.tar" "$WORK/bad_checksum.bin"
# Overwrite the 8-byte checksum field at offset 148 with 0xFF.
printf '\xff\xff\xff\xff\xff\xff\xff\xff' \
    | dd of="$WORK/bad_checksum.bin" bs=1 seek=148 count=8 conv=notrunc 2>/dev/null
install_seed "bad_checksum.bin" "$WORK/bad_checksum.bin"

# ── 8. random_512.bin — 512 random bytes ──────────────────────────────────
dd if=/dev/urandom of="$WORK/random_512.bin" bs=512 count=1 2>/dev/null
install_seed "random_512.bin" "$WORK/random_512.bin"

# ── 9. truncated.bin — valid tar truncated to 768 bytes (header + partial)
dd if="$WORK/minimal.tar" of="$WORK/truncated.bin" bs=1 count=768 2>/dev/null
install_seed "truncated.bin" "$WORK/truncated.bin"

# ── 10. large_size.tar — header with a very large size field ──────────────
# Take a valid tar, patch the size field (offset 124, 12 bytes) to max octal
# "77777777777\0" (11 octal digits + NUL), then fix the checksum.
cp "$WORK/minimal.tar" "$WORK/large_size.tar"
printf '77777777777\0' \
    | dd of="$WORK/large_size.tar" bs=1 seek=124 count=12 conv=notrunc 2>/dev/null
# Recalculate checksum for the patched header (Python one-liner for portability).
python3 -c "
import struct, sys
data = bytearray(open('$WORK/large_size.tar', 'rb').read()[:512])
# Zero out checksum field (offset 148, 8 bytes) and treat as spaces for sum
for i in range(148, 156):
    data[i] = 0x20
ac = sum(data[:512])
chk = f'{ac:06o}'.encode() + b'\x00 '
hdr = bytearray(open('$WORK/large_size.tar', 'rb').read())
hdr[148:156] = chk
open('$WORK/large_size.tar', 'wb').write(hdr)
" 2>/dev/null || true
install_seed "large_size.tar" "$WORK/large_size.tar"

# ── CLI seed corpus ──────────────────────────────────────────────────────────
# Each seed is a sequence of null-delimited strings that become argv entries
# (argv[0] = "t2sz" is prepended by the harness, so seeds start at argv[1]).

if [ -n "$CLI_DIR" ]; then
    # 1. Basic tar file argument
    printf '%s\0' "file.tar" > "$CLI_DIR/cli_basic.bin"

    # 2. Level flag
    printf '%s\0%s\0%s\0' "-l" "3" "file.tar" > "$CLI_DIR/cli_level.bin"

    # 3. Block size with suffix
    printf '%s\0%s\0%s\0' "-s" "10M" "file.tar" > "$CLI_DIR/cli_block_size.bin"

    # 4. Max block size with suffix
    printf '%s\0%s\0%s\0%s\0%s\0' "-s" "1M" "-S" "10M" "file.tar" > "$CLI_DIR/cli_both_sizes.bin"

    # 5. All boolean flags combined
    printf '%s\0%s\0%s\0%s\0' "-r" "-j" "-v" "file.bin" > "$CLI_DIR/cli_flags.bin"

    # 6. Stdin input
    printf '%s\0' "-" > "$CLI_DIR/cli_stdin.bin"

    # 7. Output to stdout
    printf '%s\0%s\0%s\0' "-o" "-" "file.tar" > "$CLI_DIR/cli_stdout.bin"

    # 8. Thread count
    printf '%s\0%s\0%s\0' "-T" "4" "file.tar" > "$CLI_DIR/cli_threads.bin"

    # 9. Various size suffixes (k, KiB, kB, KB, G, GiB, GB)
    printf '%s\0%s\0%s\0' "-s" "100KiB" "file.tar" > "$CLI_DIR/cli_suffix_kib.bin"

    # 10. Invalid level (edge case seed)
    printf '%s\0%s\0%s\0' "-l" "99" "file.tar" > "$CLI_DIR/cli_bad_level.bin"

    # 11. Overwrite flag with output file
    printf '%s\0%s\0%s\0%s\0' "-f" "-o" "out.zst" "file.tar" > "$CLI_DIR/cli_overwrite.bin"

    # 12. Version flag
    printf '%s\0' "-V" > "$CLI_DIR/cli_version.bin"

    # 13. Help flag
    printf '%s\0' "-h" > "$CLI_DIR/cli_help.bin"

    # 14. Raw mode with block size and level
    printf '%s\0%s\0%s\0%s\0%s\0' "-r" "-l" "22" "-s" "1G" > "$CLI_DIR/cli_raw_no_file.bin"

    # 15. Large numeric value for strtol edge cases
    printf '%s\0%s\0%s\0' "-s" "999999999999999999" "file.tar" > "$CLI_DIR/cli_huge_num.bin"
fi

echo "Seed corpus generated:"
echo "       $(ls "$MMAP_DIR" | wc -l | tr -d ' ') files in mmap/stdin directories."
[ -n "$CLI_DIR" ] && echo "       $(ls "$CLI_DIR" | wc -l | tr -d ' ') files in CLI directory."
