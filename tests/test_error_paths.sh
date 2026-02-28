#!/usr/bin/env bash
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
    COPYFILE_DISABLE=1 tar cf "$1" -C "$WORK" hello.txt 2>/dev/null
}

# Create a small binary non-tar file at the given path.
make_small_dat() {
    printf '\x01\x02\x03\x04\x05\x06\x07\x08' > "$1"
}

# ── Test dispatch ─────────────────────────────────────────────────────────────
case "$TEST_NAME" in

# ── CLI validation (all exit via usage() → exit 0) ───────────────────────────

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
    # t2sz to exit non-zero, covering the isTarHeader() checksum-mismatch path
    # and the "Invalid tar header" error branch in compressFile().
    make_small_tar "$WORK/corrupt.tar"
    # Overwrite the 8-byte checksum field at byte offset 148 with 0xFF bytes.
    # 0xFF is not a valid octal digit, so strtoul() returns 0, which cannot
    # match the real computed checksum, triggering the false return from
    # isTarHeader() and the subsequent exit(-1) in compressFile().
    printf '\xff\xff\xff\xff\xff\xff\xff\xff' \
        | dd of="$WORK/corrupt.tar" bs=1 seek=148 count=8 conv=notrunc 2>/dev/null
    assert_nonzero  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/corrupt.tar"
    log_pass "$TEST_NAME"
    ;;

# ── Auto raw-mode detection ───────────────────────────────────────────────────

auto_raw)
    # A file not ending in ".tar" must be treated as raw mode automatically
    # without requiring the -r flag, covering the strEndsWith() branch that
    # sets rawMode = !strEndsWith(inFilename, "tar") = true.
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

*)
    log_fail "unknown test name '$TEST_NAME'"
    exit 1
    ;;

esac
