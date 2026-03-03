#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# test_error_paths.sh — CLI validation and error-path tests for t2sz.
#
# Each invocation exercises exactly one error or edge-case code path that is
# not covered by the round-trip test suite (test_roundtrip.sh).
#
# Called by CTest via tests/CMakeLists.txt add_error_test().
#
# Usage:
#   test_error_paths.sh T2SZ BLOBS_DIR TEST_NAME
#
# Arguments:
#   T2SZ      – path to the t2sz binary under test
#   BLOBS_DIR – directory for temporary working files
#   TEST_NAME – identifier of the specific test case to run (see dispatch below)
#
# Exit codes:
#   0  test passed
#   1  test failed

set -uo pipefail

# ── Bootstrap ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/helpers.sh"

require_zstd

T2SZ="$1"
BLOBS_DIR="$2"
TEST_NAME="$3"

# ── Per-test working directory, cleaned up on exit ───────────────────────────
WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
WORK="${BLOBS_DIR}/errtest_${TEST_NAME}_$$"
mkdir -p "$WORK"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Run a command and capture its exit code in RC without aborting the script.
# Safe to use with set -e because the || operator prevents shell exit.
run() {
    RC=0
    "$@" || RC=$?
}

# Assert that the last run() call exited with EXPECTED; fail loudly otherwise.
assert_rc() {
    local expected="$1"
    if [ "$RC" -ne "$expected" ]; then
        log_fail "$TEST_NAME — expected exit $expected, got $RC"
        exit 1
    fi
}

# Run a command and assert it exits with EXPECTED.
assert_exit() {
    local expected="$1"; shift
    run "$@"
    assert_rc "$expected"
}

# Run a command and assert it exits with any non-zero code.
assert_nonzero() {
    run "$@"
    if [ "$RC" -eq 0 ]; then
        log_fail "$TEST_NAME — expected non-zero exit, got 0: $*"
        exit 1
    fi
}

# Create a minimal valid single-file tar archive at the given path.
# COPYFILE_DISABLE=1 suppresses macOS extended-attribute sidecar files.
make_small_tar() {
    printf 'hello t2sz error tests\n' > "$WORK/hello.txt"
    COPYFILE_DISABLE=1 tar cf "$1" -C "$WORK" hello.txt 2>/dev/null || return 1
}

# Create a small binary non-tar file at the given path.
make_small_dat() {
    printf '\x01\x02\x03\x04\x05\x06\x07\x08' > "$1"
}

# ── Test dispatch ─────────────────────────────────────────────────────────────
case "$TEST_NAME" in

# ── CLI validation (validation failures exit via usage() → exit 1) ────────────

no_args)
    # No input file argument: t2sz must print usage and exit 1.
    assert_exit 1  "$T2SZ"
    log_pass "$TEST_NAME"
    ;;

too_many_args)
    # Two positional arguments: t2sz must print "Too many arguments" and exit 1.
    assert_exit 1  "$T2SZ" file_a file_b
    log_pass "$TEST_NAME"
    ;;

bad_level_low)
    # -l 0 is below the valid range [1..22]: must print usage and exit 1.
    assert_exit 1  "$T2SZ" -l 0 dummy
    log_pass "$TEST_NAME"
    ;;

bad_level_high)
    # -l 23 is above the valid range [1..22]: must print usage and exit 1.
    assert_exit 1  "$T2SZ" -l 23 dummy
    log_pass "$TEST_NAME"
    ;;

bad_block_s)
    # -s 0 produces a zero minimum block size (0 < multiplier=1): exit 1.
    assert_exit 1  "$T2SZ" -s 0 dummy
    log_pass "$TEST_NAME"
    ;;

bad_block_S)
    # -S 0 produces a zero maximum block size (0 < multiplier=1): exit 1.
    assert_exit 1  "$T2SZ" -S 0 dummy
    log_pass "$TEST_NAME"
    ;;

bad_threads)
    # -T 0 is below the valid minimum of 1 thread: must print usage and exit 1.
    assert_exit 1  "$T2SZ" -T 0 dummy
    log_pass "$TEST_NAME"
    ;;

block_S_lt_s)
    # Maximum block size (-S 1M) smaller than minimum (-s 2M): must exit 1.
    assert_exit 1  "$T2SZ" -s 2M -S 1M dummy
    log_pass "$TEST_NAME"
    ;;

help)
    # -h must print the full help text (covering usage() and version()) and exit 0.
    assert_exit 0  "$T2SZ" -h
    log_pass "$TEST_NAME"
    ;;

version)
    # -V must print version information (covering version()) and exit 0.
    assert_exit 0  "$T2SZ" -V
    log_pass "$TEST_NAME"
    ;;

# ── File-system error paths ───────────────────────────────────────────────────

file_not_found)
    # A non-existent input file triggers the access(F_OK) check → return 1.
    assert_exit 1  "$T2SZ" "$WORK/definitely_nonexistent.tar"
    log_pass "$TEST_NAME"
    ;;

output_bad_path)
    # When the output path cannot be opened for writing (it is a directory),
    # fopen() returns NULL and prepareOutput() calls exit(1).
    make_small_tar "$WORK/input.tar"
    mkdir -p "$WORK/isdir"
    assert_exit 1  "$T2SZ" -o "$WORK/isdir" -f "$WORK/input.tar"
    log_pass "$TEST_NAME"
    ;;

# ── Interactive overwrite prompt ──────────────────────────────────────────────

overwrite_no)
    # Answering 'n' to the overwrite prompt must leave the output file unchanged
    # and return exit code 0, covering the scanf branch where ans != 'y'.
    make_small_dat "$WORK/input.dat"
    printf 'SENTINEL' > "$WORK/out.zst"
    RC=0
    echo n | "$T2SZ" -o "$WORK/out.zst" "$WORK/input.dat" 2>/dev/null || RC=$?
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — expected exit 0, got $RC"; exit 1; }
    content=$(cat "$WORK/out.zst")
    if [ "$content" != "SENTINEL" ]; then
        log_fail "$TEST_NAME — output file was overwritten despite answering 'n'"
        exit 1
    fi
    log_pass "$TEST_NAME"
    ;;

overwrite_yes)
    # Answering 'y' to the overwrite prompt must replace the output file and
    # return exit code 0, covering the scanf branch where ans == 'y'.
    make_small_dat "$WORK/input.dat"
    printf 'x' > "$WORK/out.zst"    # 1-byte placeholder
    RC=0
    echo y | "$T2SZ" -o "$WORK/out.zst" "$WORK/input.dat" 2>/dev/null || RC=$?
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — expected exit 0, got $RC"; exit 1; }
    # A valid compressed output must be larger than the 1-byte placeholder.
    bytes=$(wc -c < "$WORK/out.zst")
    [ $((bytes + 0)) -gt 1 ] || {
        log_fail "$TEST_NAME — output file was not overwritten after answering 'y'"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

# ── Corrupted tar input ───────────────────────────────────────────────────────

corrupt_tar)
    # A tar archive whose header checksum field has been corrupted must cause
    # t2sz to exit with EXIT_FAILURE, covering the isTarHeader() checksum-mismatch
    # path and the "Invalid tar header" error branch in compressFile().
    make_small_tar "$WORK/corrupt.tar"
    # Overwrite the 8-byte checksum field at byte offset 148 with 0xFF bytes.
    # 0xFF is not a valid octal digit, so strtoul() returns 0, which cannot
    # match the real computed checksum, causing isTarHeader() to return false
    # and compressFile() to report an invalid tar header and exit with failure.
    printf '\xff\xff\xff\xff\xff\xff\xff\xff' \
        | dd of="$WORK/corrupt.tar" bs=1 seek=148 count=8 conv=notrunc 2>/dev/null
    assert_nonzero  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/corrupt.tar"
    log_pass "$TEST_NAME"
    ;;

# ── Auto raw-mode detection ───────────────────────────────────────────────────

auto_raw)
    # A file not ending in ".tar" must be treated as raw mode automatically
    # without requiring the -r flag, covering the strEndsWith() branch that
    # sets rawMode = !strEndsWith(inFilename, ".tar") = true.
    make_small_dat "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/input.dat"
    log_pass "$TEST_NAME"
    ;;

auto_outname)
    # Run t2sz without -o so that getOutFilename() is called to derive the
    # default output path by appending ".zst" to the input filename.
    make_small_dat "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -f "$WORK/input.dat"
    [ -f "$WORK/input.dat.zst" ] || {
        log_fail "$TEST_NAME — expected auto-generated file input.dat.zst not found"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

multiplier_suffixes)
    # Exercise the metric-prefix branches of decodeMultiplier() that are not
    # reached by the standard flag tests (which only use k/K and M/MiB).
    #
    #   GiB → 1024^3  (branch at the third else-if)
    #   kB  → 1000    (fourth else-if)
    #   KB  → 1000    (fourth else-if, same branch)
    #   MB  → 1000^2  (fifth else-if)
    #   GB  → 1000^3  (sixth else-if)
    #
    # A tiny 8-byte input is used so the actual block size is capped to the
    # file size regardless of the large multiplier value.
    make_small_dat "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1GiB -o "$WORK/out_gib.zst" -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1kB  -o "$WORK/out_kb.zst"  -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1KB  -o "$WORK/out_KB.zst"  -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1MB  -o "$WORK/out_MB.zst"  -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1GB  -o "$WORK/out_GB.zst"  -f "$WORK/input.dat"
    log_pass "$TEST_NAME"
    ;;

# ── Stdin / stdout support ────────────────────────────────────────────────────

stdin_empty_raw)
    # Compressing empty stdin in raw mode: t2sz must not crash, must exit 0,
    # and must produce a valid (empty) zstd output file.
    assert_exit 0  "$T2SZ" -r -o "$WORK/empty.zst" -f - < /dev/null
    [ -f "$WORK/empty.zst" ] || {
        log_fail "$TEST_NAME — no output file produced"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

stdin_empty_tar_mode)
    # Truly empty stdin in tar mode (no -r): must fail because 0 bytes is not
    # a valid tar archive.  Ensures we don't silently produce a 0-frame output
    # with exit 0 (which would mask a broken pipeline).
    assert_nonzero "$T2SZ" -o "$WORK/empty.zst" -f - < /dev/null
    log_pass "$TEST_NAME"
    ;;

mmap_tiny_tar)
    # A file smaller than 512 bytes is not a valid tar archive.
    # Tar mode (mmap path) must fail, not silently produce 0 frames.
    dd if=/dev/zero bs=100 count=1 2>/dev/null > "$WORK/tiny.tar"
    assert_nonzero "$T2SZ" -o "$WORK/out.zst" -f "$WORK/tiny.tar"
    log_pass "$TEST_NAME"
    ;;

stdin_default_stdout)
    # With "-" as input and no -o, output must go to stdout by default.
    # Verify the captured stdout is a valid zstd stream.
    make_small_dat "$WORK/input.dat"
    "$T2SZ" -r - < "$WORK/input.dat" > "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — t2sz exited non-zero"
        exit 1
    }
    zstd -t -q "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — stdout output is not a valid zstd stream"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

stdin_file_stdout)
    # -o - with a regular file input must send compressed output to stdout.
    make_small_dat "$WORK/input.dat"
    "$T2SZ" -r -o - -f "$WORK/input.dat" > "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — t2sz exited non-zero"
        exit 1
    }
    zstd -t -q "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — stdout output is not a valid zstd stream"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

# ── Stdin streaming error paths ──────────────────────────────────────────────

stdin_corrupt_tar)
    # Corrupted tar via stdin → isTarHeader() failure in compressStdinTar.
    make_small_tar "$WORK/corrupt.tar"
    printf '\xff\xff\xff\xff\xff\xff\xff\xff' \
        | dd of="$WORK/corrupt.tar" bs=1 seek=148 count=8 conv=notrunc 2>/dev/null
    assert_nonzero "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/corrupt.tar"
    log_pass "$TEST_NAME"
    ;;

stdin_empty_tar)
    # Empty tar (tar with zero-byte file) via stdin — exercises isZeroTarBlock().
    # Must not crash. Non-zero exit is acceptable (like the mmap empty_tar test).
    touch "$WORK/empty"
    (cd "$WORK" && COPYFILE_DISABLE=1 tar cf empty.tar empty) || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    RC=0
    "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/empty.tar" 2>/dev/null || RC=$?
    if [ "$RC" -gt 128 ]; then
        log_fail "$TEST_NAME — killed by signal $(( RC - 128 ))"
        exit 1
    fi
    log_pass "$TEST_NAME — exited $RC (no crash)"
    ;;

stdin_truncated_tar)
    # Partial 512-byte header on stdin → "Truncated tar header" error.
    # Send exactly 256 zero bytes: fread returns 256, r != 512 triggers the error.
    dd if=/dev/zero of="$WORK/partial.bin" bs=1 count=256 2>/dev/null
    assert_nonzero "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/partial.bin"
    log_pass "$TEST_NAME"
    ;;

stdin_truncated_payload)
    # Tar header declares a file but data is cut short → readExactStdin() EOF.
    make_small_tar "$WORK/good.tar"
    # good.tar ≈ 2048B: 512B header + 512B data block + 1024B end blocks.
    # Truncate to 768B: header complete, only 256 of 512 data bytes remain.
    dd if="$WORK/good.tar" of="$WORK/trunc.tar" bs=1 count=768 2>/dev/null
    assert_nonzero "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/trunc.tar"
    log_pass "$TEST_NAME"
    ;;

stdout_tar_file)
    # -o - with a tar file input must produce valid zstd on stdout (mmap + stdout).
    make_small_tar "$WORK/input.tar"
    "$T2SZ" -o - -f "$WORK/input.tar" > "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — t2sz failed"
        exit 1
    }
    zstd -t -q "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — stdout output is not a valid zstd stream"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

empty_file)
    # A zero-byte input file must trigger "Empty input file" error in prepareInput().
    touch "$WORK/empty.bin"
    assert_nonzero "$T2SZ" -r -o "$WORK/out.zst" -f "$WORK/empty.bin"
    log_pass "$TEST_NAME"
    ;;

# ── Seek table structural verification ──────────────────────────────────────

noseek_verify)
    # Compress with -j and verify the seekable-zstd magic is truly absent.
    # Covers writeSeekTable() gating via ctx->skipSeekTable.
    make_small_dat "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -j -o "$WORK/out.zst" -f "$WORK/input.dat"
    verify_no_seek_table "$WORK/out.zst" || {
        log_fail "$TEST_NAME — seek table magic found despite -j"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

# ── Raw -s with non-multiple input size ─────────────────────────────────────

raw_nonmultiple_s)
    # Input size 1000001 bytes, -s 256k (262144). Not a multiple.
    # Expected frames: ceil(1000001 / 262144) = 4 (last frame is 213569 bytes).
    # Round-trip SHA-256 + seek table verification.
    head -c 1000001 /dev/urandom > "$WORK/input.bin"
    sha_before=$(sha256_file "$WORK/input.bin")
    assert_exit 0  "$T2SZ" -r -s 256k -o "$WORK/out.zst" -f "$WORK/input.bin"
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.bin" || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    sha_after=$(sha256_file "$WORK/dec.bin")
    if [ "$sha_before" != "$sha_after" ]; then
        log_fail "$TEST_NAME — SHA mismatch"
        log_info "before: $sha_before"
        log_info "after:  $sha_after"
        exit 1
    fi
    verify_seek_table "$WORK/out.zst" 4 || exit 1
    log_pass "$TEST_NAME"
    ;;

stdin_raw_nonmultiple_s)
    # Same as raw_nonmultiple_s but via stdin, exercising compressStdinRaw() Path B.
    head -c 1000001 /dev/urandom > "$WORK/input.bin"
    sha_before=$(sha256_file "$WORK/input.bin")
    assert_exit 0  "$T2SZ" -r -s 256k -o "$WORK/out.zst" -f - < "$WORK/input.bin"
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.bin" || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    sha_after=$(sha256_file "$WORK/dec.bin")
    if [ "$sha_before" != "$sha_after" ]; then
        log_fail "$TEST_NAME — SHA mismatch"
        exit 1
    fi
    verify_seek_table "$WORK/out.zst" 4 || exit 1
    log_pass "$TEST_NAME"
    ;;

# ── Tar trailing junk after end-of-archive ──────────────────────────────────

trailing_junk_tar)
    # Create a valid tar, then append 1024 bytes of non-zero junk (0xAA) after
    # the end-of-archive blocks. Both mmap and stdin paths read until EOF, so
    # both will encounter the junk, fail isTarHeader(), and exit non-zero.
    # The test verifies neither path crashes (no signal kill).
    make_small_tar "$WORK/good.tar"
    cp "$WORK/good.tar" "$WORK/junk.tar"
    dd if=/dev/zero bs=1 count=1024 2>/dev/null | tr '\0' '\252' >> "$WORK/junk.tar"

    # mmap path: must not crash (exit non-zero is expected)
    RC=0
    "$T2SZ" -o "$WORK/out_mmap.zst" -f "$WORK/junk.tar" 2>/dev/null || RC=$?
    if [ "$RC" -gt 128 ]; then
        log_fail "$TEST_NAME — mmap path killed by signal $(( RC - 128 ))"
        exit 1
    fi
    log_step "mmap path exited $RC (no crash)"

    # stdin path: must not crash (exit non-zero is expected)
    RC=0
    "$T2SZ" -o "$WORK/out_stdin.zst" -f - < "$WORK/junk.tar" 2>/dev/null || RC=$?
    if [ "$RC" -gt 128 ]; then
        log_fail "$TEST_NAME — stdin path killed by signal $(( RC - 128 ))"
        exit 1
    fi
    log_step "stdin path exited $RC (no crash)"

    log_pass "$TEST_NAME"
    ;;

# ── Non-regular tar entries (dirs, symlinks) ────────────────────────────────

tar_with_dirs_symlinks)
    # Create a tar containing a directory, a regular file, and a symlink.
    # The parser ignores typeflag and uses the size field; dirs/symlinks have
    # size=0 so no data bytes are read. Must not crash and round-trip correctly.
    mkdir -p "$WORK/content/subdir"
    printf 'hello from t2sz tests\n' > "$WORK/content/file.txt"
    ln -s file.txt "$WORK/content/link.txt"
    (cd "$WORK/content" && COPYFILE_DISABLE=1 tar cf "$WORK/archive.tar" subdir file.txt link.txt) || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    assert_exit 0  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/archive.tar"
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.tar" || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    mkdir -p "$WORK/extracted"
    tar xf "$WORK/dec.tar" -C "$WORK/extracted" || {
        log_fail "$TEST_NAME — tar extraction failed"
        exit 1
    }
    # Verify the directory exists
    [ -d "$WORK/extracted/subdir" ] || {
        log_fail "$TEST_NAME — subdir not extracted"
        exit 1
    }
    # Verify the symlink exists and points to file.txt
    [ -L "$WORK/extracted/link.txt" ] || {
        log_fail "$TEST_NAME — link.txt is not a symlink"
        exit 1
    }
    target=$(readlink "$WORK/extracted/link.txt")
    [ "$target" = "file.txt" ] || {
        log_fail "$TEST_NAME — symlink target is '$target', expected 'file.txt'"
        exit 1
    }
    # Verify the regular file content
    expected=$(sha256_file "$WORK/content/file.txt")
    actual=$(sha256_file "$WORK/extracted/file.txt")
    [ "$expected" = "$actual" ] || {
        log_fail "$TEST_NAME — file.txt SHA mismatch"
        exit 1
    }
    # Verify seek table structural integrity
    verify_seek_table_structure "$WORK/out.zst" || exit 1
    log_pass "$TEST_NAME"
    ;;

# ── Explicit -o - with stdin ────────────────────────────────────────────────

stdin_explicit_stdout_raw)
    # stdin raw mode with explicit -o - (not relying on default stdout).
    # Exercises the stdoutMode path when both input is stdin and output is explicit stdout.
    make_small_dat "$WORK/input.dat"
    sha_before=$(sha256_file "$WORK/input.dat")
    "$T2SZ" -r -o - -f - < "$WORK/input.dat" > "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — t2sz exited non-zero"
        exit 1
    }
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.dat" 2>/dev/null || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    sha_after=$(sha256_file "$WORK/dec.dat")
    if [ "$sha_before" != "$sha_after" ]; then
        log_fail "$TEST_NAME — SHA mismatch"
        exit 1
    fi
    log_pass "$TEST_NAME"
    ;;

stdin_explicit_stdout_tar)
    # stdin tar mode with explicit -o - (not relying on default stdout).
    make_small_tar "$WORK/input.tar"
    "$T2SZ" -o - -f - < "$WORK/input.tar" > "$WORK/out.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — t2sz exited non-zero"
        exit 1
    }
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.tar" 2>/dev/null || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    mkdir -p "$WORK/extracted"
    tar xf "$WORK/dec.tar" -C "$WORK/extracted" 2>/dev/null || {
        log_fail "$TEST_NAME — tar extraction failed"
        exit 1
    }
    # Verify hello.txt from make_small_tar
    [ -f "$WORK/extracted/hello.txt" ] || {
        log_fail "$TEST_NAME — hello.txt not found"
        exit 1
    }
    expected="hello t2sz error tests"
    actual=$(cat "$WORK/extracted/hello.txt")
    if [ "$actual" != "$expected" ]; then
        log_fail "$TEST_NAME — content mismatch (got '$actual')"
        exit 1
    fi
    log_pass "$TEST_NAME"
    ;;

# ── Argument parsing edge cases: strtol failures ────────────────────────────

bad_level_strtol)
    # Exercises strtol() edge cases in -l argument parsing:
    #   endptr == optarg (non-numeric), *endptr != '\0' (trailing garbage),
    #   ERANGE (overflow beyond LONG_MAX), negative value.
    assert_exit 1  "$T2SZ" -l abc dummy
    assert_exit 1  "$T2SZ" -l 3abc dummy
    assert_exit 1  "$T2SZ" -l 99999999999999999999 dummy
    assert_exit 1  "$T2SZ" -l -1 dummy
    log_pass "$TEST_NAME"
    ;;

bad_block_s_strtol)
    # Exercises strtol() edge cases in -s argument parsing:
    #   endptr == optarg (non-numeric), trailing garbage (unrecognized suffix),
    #   ERANGE (overflow), negative value.
    assert_exit 1  "$T2SZ" -s abc dummy
    assert_exit 1  "$T2SZ" -s 2abc dummy
    assert_exit 1  "$T2SZ" -s 99999999999999999999 dummy
    assert_exit 1  "$T2SZ" -s -1 dummy
    log_pass "$TEST_NAME"
    ;;

bad_block_S_strtol)
    # Exercises strtol() edge cases in -S argument parsing:
    #   endptr == optarg (non-numeric), trailing garbage (unrecognized suffix),
    #   ERANGE (overflow), negative value.
    assert_exit 1  "$T2SZ" -S abc dummy
    assert_exit 1  "$T2SZ" -S 2abc dummy
    assert_exit 1  "$T2SZ" -S 99999999999999999999 dummy
    assert_exit 1  "$T2SZ" -S -1 dummy
    log_pass "$TEST_NAME"
    ;;

bad_threads_strtol)
    # Exercises strtol() edge cases in -T argument parsing:
    #   endptr == optarg (non-numeric), *endptr != '\0' (trailing garbage),
    #   ERANGE (overflow beyond LONG_MAX), val > UINT32_MAX, negative value.
    assert_exit 1  "$T2SZ" -T abc dummy
    assert_exit 1  "$T2SZ" -T 2abc dummy
    assert_exit 1  "$T2SZ" -T 99999999999999999999 dummy
    assert_exit 1  "$T2SZ" -T 4294967296 dummy
    assert_exit 1  "$T2SZ" -T -1 dummy
    log_pass "$TEST_NAME"
    ;;

# ── Unknown option — getopt '?' → switch default case ──────────────────────

unknown_option)
    # Unrecognized option -Z triggers getopt '?' → switch default case.
    # usage(executable, "ERROR: Unknown option") exits with EXIT_FAILURE (1).
    assert_exit 1  "$T2SZ" -Z dummy 2>/dev/null
    log_pass "$TEST_NAME"
    ;;

# ── decodeMultiplier extra suffixes (K/KiB/MiB/G) ─────────────────────────

multiplier_suffixes_extra)
    # Exercises decodeMultiplier() branches not covered by multiplier_suffixes:
    #   K (uppercase alone) → 1024, KiB → 1024, MiB → 1024², G → 1024³.
    # Each suffix variant must produce a valid round-trip with SHA-256 match.
    make_small_dat "$WORK/input.dat"
    sha_before=$(sha256_file "$WORK/input.dat")

    assert_exit 0  "$T2SZ" -r -s 1K   -o "$WORK/out_K.zst"   -f "$WORK/input.dat"
    zstd -d -f -q "$WORK/out_K.zst" -o "$WORK/dec_K.dat" || { log_fail "$TEST_NAME — K decomp failed"; exit 1; }
    sha_after=$(sha256_file "$WORK/dec_K.dat")
    [ "$sha_before" = "$sha_after" ] || { log_fail "$TEST_NAME — K SHA mismatch"; exit 1; }

    assert_exit 0  "$T2SZ" -r -s 1KiB -o "$WORK/out_KiB.zst" -f "$WORK/input.dat"
    zstd -d -f -q "$WORK/out_KiB.zst" -o "$WORK/dec_KiB.dat" || { log_fail "$TEST_NAME — KiB decomp failed"; exit 1; }
    sha_after=$(sha256_file "$WORK/dec_KiB.dat")
    [ "$sha_before" = "$sha_after" ] || { log_fail "$TEST_NAME — KiB SHA mismatch"; exit 1; }

    assert_exit 0  "$T2SZ" -r -s 1MiB -o "$WORK/out_MiB.zst" -f "$WORK/input.dat"
    zstd -d -f -q "$WORK/out_MiB.zst" -o "$WORK/dec_MiB.dat" || { log_fail "$TEST_NAME — MiB decomp failed"; exit 1; }
    sha_after=$(sha256_file "$WORK/dec_MiB.dat")
    [ "$sha_before" = "$sha_after" ] || { log_fail "$TEST_NAME — MiB SHA mismatch"; exit 1; }

    assert_exit 0  "$T2SZ" -r -s 1G   -o "$WORK/out_G.zst"   -f "$WORK/input.dat"
    zstd -d -f -q "$WORK/out_G.zst" -o "$WORK/dec_G.dat" || { log_fail "$TEST_NAME — G decomp failed"; exit 1; }
    sha_after=$(sha256_file "$WORK/dec_G.dat")
    [ "$sha_before" = "$sha_after" ] || { log_fail "$TEST_NAME — G SHA mismatch"; exit 1; }

    log_pass "$TEST_NAME"
    ;;

# ── Stdin overwrite protection ────────────────────────────────────────────

stdin_overwrite_no_force)
    # Piping data through stdin with an existing output file and no -f flag.
    # An interactive prompt would corrupt the pipe, so t2sz must refuse with
    # a clear error message and exit 1 instead of calling scanf().
    make_small_dat "$WORK/input.dat"
    printf 'SENTINEL' > "$WORK/existing.zst"
    RC=0
    "$T2SZ" -r -o "$WORK/existing.zst" - < "$WORK/input.dat" 2>"$WORK/stderr.txt" || RC=$?
    [ "$RC" -eq 1 ] || {
        log_fail "$TEST_NAME — expected exit 1, got $RC"
        exit 1
    }
    # Verify the error message mentions -f
    if ! grep -q "already exists" "$WORK/stderr.txt" || ! grep -q "\-f" "$WORK/stderr.txt"; then
        log_fail "$TEST_NAME — expected 'already exists ... -f' on stderr"
        cat "$WORK/stderr.txt" >&2
        exit 1
    fi
    # Output file must be untouched
    content=$(cat "$WORK/existing.zst")
    if [ "$content" != "SENTINEL" ]; then
        log_fail "$TEST_NAME — output file was modified"
        exit 1
    fi
    log_pass "$TEST_NAME"
    ;;

stdin_overwrite_force)
    # Piping data through stdin with an existing output file and -f flag.
    # Must succeed, overwriting the file without prompting.
    make_small_dat "$WORK/input.dat"
    printf 'x' > "$WORK/existing.zst"
    assert_exit 0  "$T2SZ" -r -f -o "$WORK/existing.zst" - < "$WORK/input.dat"
    # Verify a valid zstd file was written (larger than 1-byte placeholder).
    bytes=$(wc -c < "$WORK/existing.zst")
    [ $((bytes + 0)) -gt 1 ] || {
        log_fail "$TEST_NAME — output file was not overwritten"
        exit 1
    }
    zstd -t -q "$WORK/existing.zst" 2>/dev/null || {
        log_fail "$TEST_NAME — output is not valid zstd"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

# ── Overflow guard for -s/-S multiplication ──────────────────────────────

overflow_s)
    # A huge numeric value with a large suffix triggers the overflow guard
    # in case 's': (size_t)val > SIZE_MAX / multiplier → exit 1.
    # 999999999999 × GiB (1024³) exceeds SIZE_MAX on 64-bit.
    assert_exit 1  "$T2SZ" -s 999999999999GiB dummy
    log_pass "$TEST_NAME"
    ;;

overflow_S)
    # Same overflow guard for case 'S' (maxBlockSize).
    assert_exit 1  "$T2SZ" -S 999999999999GiB dummy
    log_pass "$TEST_NAME"
    ;;

# ── seekTableEnsureCap realloc growth (>1024 frames) ──────────────────────

seektable_grow)
    # Compress 1049600 bytes (1025 × 1024) with -s 1k to produce 1025 frames.
    # This exceeds the initial seek table capacity (1024 entries), triggering
    # seekTableEnsureCap() to grow: realloc from 1024 → 2048 entries.
    # Covers both branch (180:21) ctx->seekTableCap ternary True path
    # and branch (181:12) while(newCap < needed) loop body.
    dd if=/dev/urandom of="$WORK/input.bin" bs=1024 count=1025 2>/dev/null
    sha_before=$(sha256_file "$WORK/input.bin")
    assert_exit 0  "$T2SZ" -r -s 1k -o "$WORK/out.zst" -f "$WORK/input.bin"
    zstd -d -f -q "$WORK/out.zst" -o "$WORK/dec.bin" || {
        log_fail "$TEST_NAME — decompression failed"
        exit 1
    }
    sha_after=$(sha256_file "$WORK/dec.bin")
    if [ "$sha_before" != "$sha_after" ]; then
        log_fail "$TEST_NAME — SHA mismatch"
        exit 1
    fi
    verify_seek_table "$WORK/out.zst" 1025 || exit 1
    log_pass "$TEST_NAME"
    ;;

# ── Garbage between number and suffix in -s/-S ──────────────────────────────

garbage_suffix)
    # Exercises the decodeMultiplier() fix: garbage characters between the
    # numeric value and a valid suffix (e.g. "1xyzGiB") must be rejected.
    # Before the fix, strEndsWith() would match the trailing "GiB" and
    # silently accept the argument.
    assert_exit 1  "$T2SZ" -s 1xyzGiB dummy
    assert_exit 1  "$T2SZ" -S 1xyzGiB dummy
    assert_exit 1  "$T2SZ" -s 10fooM dummy
    assert_exit 1  "$T2SZ" -S 10fooM dummy
    assert_exit 1  "$T2SZ" -s 5barKiB dummy
    assert_exit 1  "$T2SZ" -S 5barKiB dummy
    # Valid suffixes must still be accepted (file not found, not block-size error)
    make_small_dat "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1GiB -o "$WORK/out1.zst" -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1M   -o "$WORK/out2.zst" -f "$WORK/input.dat"
    assert_exit 0  "$T2SZ" -r -s 1k   -o "$WORK/out3.zst" -f "$WORK/input.dat"
    log_pass "$TEST_NAME"
    ;;

*)
    log_fail "unknown test name '$TEST_NAME'"
    exit 1
    ;;

esac
