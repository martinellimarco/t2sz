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

# Run a command and assert it fails the way t2sz fails: with EXIT_FAILURE (1).
# Any other non-zero code is a crash: a signal, or a sanitizer error (66).
assert_nonzero() {
    assert_exit 1 "$@"
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

# Assert that t2sz rejects the options "$@" with exit 1 and writes nothing.
# It runs on an existing input, so that only the options can make it fail:
# with a missing input it would fail even with the check under test removed.
assert_rejected() {
    make_small_dat "$WORK/valid.dat"
    assert_exit 1  "$T2SZ" -f -o "$WORK/rejected.zst" "$@" "$WORK/valid.dat"
    [ ! -e "$WORK/rejected.zst" ] || { log_fail "$TEST_NAME — output written although $* was rejected"; exit 1; }
}

# Assert that the zstd file $1 decompresses to exactly the bytes of $2.
# Hashes rather than cmp: macOS cmp reads a pipe one byte at a time (35 MB/s).
assert_roundtrip() {
    if [ "$(zstd -d -c -q "$1" 2>/dev/null | $SHA256CMD | awk '{print $1}')" != "$(sha256_file "$2")" ]; then
        log_fail "$TEST_NAME — $(basename "$1") does not decompress to $(basename "$2")"
        exit 1
    fi
}

# Create $1: a sparse file of $2 bytes, all zeros except the marker T2SZMARK
# at its start and a 'Z' as its last byte.
make_big_file() {
    make_sparse "$1" "$2"
    poke "$1" 0 T2SZMARK
    poke "$1" $(( $2 - 1 )) Z
}

# Build $3: a tar archive with one member "big" of $2 bytes, made by
# make_big_file. The headers come from the real tar in format $1 (ustar, gnu
# or pax); the payload is a hole, so the archive costs no disk space where
# sparse files are supported.
make_big_member_tar() {
    local fmt="$1" size="$2" out="$3" flags off
    mkdir -p "$WORK/bigsrc"
    make_big_file "$WORK/bigsrc/big" "$size"
    flags="--format=$fmt"
    if ! tar --version 2>/dev/null | grep -q 'GNU tar'; then
        # bsdtar: GNU format has another name, and holes must be stored as
        # plain zeros, not as a sparse entry (GNU tar does that by default).
        [ "$fmt" = gnu ] && flags="--format=gnutar"
        flags="$flags --no-read-sparse"
    fi
    # Only the first records are needed: head closes the pipe and tar stops.
    { COPYFILE_DISABLE=1 tar $flags -cf - -C "$WORK/bigsrc" big | head -c 65536 > "$WORK/prefix.bin"; } 2>/dev/null
    off=$(grep -abo T2SZMARK "$WORK/prefix.bin" | head -n 1 | cut -d: -f1)
    if [ -z "$off" ]; then
        log_fail "$TEST_NAME — tar $flags produced no payload for the big member"
        exit 1
    fi
    make_sparse "$out" $(( off + (size + 511) / 512 * 512 + 1024 ))
    head -c $(( off + 8 )) "$WORK/prefix.bin" | dd of="$out" conv=notrunc 2>/dev/null
    poke "$out" $(( off + size - 1 )) Z
    rm -f "$WORK/bigsrc/big"
}

# Run "$@" on a terminal: script(1) gives it a pseudo-terminal as stdin,
# stdout and stderr, and types the text $1 into it. Sets RC like run(); what
# the terminal shows is in "$WORK/tty.out". Skips the test where there is no
# terminal to give: without script(1), and on Windows, where an MSYS pty is
# a pipe to native programs.
run_in_terminal() {
    local input="$1" cmd n=0
    shift
    is_windows && { log_skip "$TEST_NAME — no terminal for native Windows programs"; exit 77; }
    cmd="$(printf '%q ' "$@"); echo \$? > '$WORK/tty.rc'"
    rm -f "$WORK/tty.rc"    # left by an earlier call of the same test
    # Keep typing open until the command ends: BSD script(1) sends the
    # terminal an end-of-file as soon as its stdin closes, ahead of the text.
    type_input() {
        printf '%s' "$input"
        while [ ! -e "$WORK/tty.rc" ] && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
    }
    if script -q /dev/null true < /dev/null > /dev/null 2>&1; then         # BSD
        type_input | script -q /dev/null sh -c "$cmd" > "$WORK/tty.out" 2>&1
    elif script -q -c true /dev/null < /dev/null > /dev/null 2>&1; then    # util-linux
        type_input | script -q -c "$cmd" /dev/null > "$WORK/tty.out" 2>&1
    else
        log_skip "$TEST_NAME — no script(1) to provide a terminal"
        exit 77
    fi
    RC=$(cat "$WORK/tty.rc")
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
    assert_rejected "$WORK/valid.dat"
    log_pass "$TEST_NAME"
    ;;

bad_level_low)
    # -l 0 is below the valid range [1..22]: must print usage and exit 1.
    assert_rejected -l 0
    log_pass "$TEST_NAME"
    ;;

bad_level_high)
    # -l 23 is above the valid range [1..22]: must print usage and exit 1.
    assert_rejected -l 23
    log_pass "$TEST_NAME"
    ;;

bad_block_s)
    # -s 0 produces a zero minimum block size (0 < multiplier=1): exit 1.
    assert_rejected -s 0
    log_pass "$TEST_NAME"
    ;;

bad_block_S)
    # -S 0 produces a zero maximum block size (0 < multiplier=1): exit 1.
    assert_rejected -S 0
    log_pass "$TEST_NAME"
    ;;

bad_threads)
    # -T 0 is below the valid minimum of 1 thread: must print usage and exit 1.
    assert_rejected -T 0
    log_pass "$TEST_NAME"
    ;;

block_S_lt_s)
    # Maximum block size (-S 1M) smaller than minimum (-s 2M): must exit 1.
    assert_rejected -s 2M -S 1M
    log_pass "$TEST_NAME"
    ;;

help)
    # -h must print the full help text (covering usage() and version()) and exit 0.
    assert_exit 0  "$T2SZ" -h
    log_pass "$TEST_NAME"
    ;;

help_program_name)
    # The help text uses positional printf arguments (%1$s), which the
    # Windows C runtime does not support.
    out=$("$T2SZ" -h 2>&1)
    case "$out" in
        *'$s'*) log_fail "$TEST_NAME — help text shows a literal \$s"; exit 1 ;;
    esac
    printf '%s\n' "$out" | grep -q '^Usage: .*t2sz' || {
        log_fail "$TEST_NAME — no usage line with the program name"
        exit 1
    }
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

close_error_exit)
    # The last buffered bytes reach the file only in fclose() (or fflush()
    # for stdout), whose result is ignored: a write error there leaves a
    # truncated archive and exit 0. ulimit -f 1, with SIGXFSZ ignored, makes
    # write() fail with EFBIG past 1 KiB; the ~2 KiB output stays in the
    # stdio buffer until the end.
    is_windows && { log_skip "$TEST_NAME — ulimit -f has no effect on Windows"; exit 77; }
    head -c 2000 /dev/urandom > "$WORK/input.bin"
    RC=0
    ( trap '' XFSZ; ulimit -f 1; exec "$T2SZ" -r -f -o "$WORK/out.zst" "$WORK/input.bin" ) 2>/dev/null || RC=$?
    [ "$RC" -ne 0 ] || {
        log_fail "$TEST_NAME — -o file: exit 0 with an archive cut to $(wc -c < "$WORK/out.zst" | tr -d ' ') bytes"
        exit 1
    }
    assert_rc 1
    RC=0
    ( trap '' XFSZ; ulimit -f 1; exec "$T2SZ" -r -o - "$WORK/input.bin" > "$WORK/stdout.zst" ) 2>/dev/null || RC=$?
    [ "$RC" -ne 0 ] || {
        log_fail "$TEST_NAME — -o -: exit 0 with an archive cut to $(wc -c < "$WORK/stdout.zst" | tr -d ' ') bytes"
        exit 1
    }
    assert_rc 1
    # A closed stdout fails the same way: the archive is lost.
    run "$T2SZ" -r -o - "$WORK/input.bin" >&- 2>/dev/null
    [ "$RC" -ne 0 ] || { log_fail "$TEST_NAME — -o - with stdout closed: exit 0, archive lost"; exit 1; }
    assert_rc 1
    log_pass "$TEST_NAME"
    ;;

# ── Interactive overwrite prompt ──────────────────────────────────────────────

overwrite_no)
    # Answering 'n' to the overwrite prompt on a terminal must leave the output
    # file unchanged and return exit code 0.
    make_small_dat "$WORK/input.dat"
    printf 'SENTINEL' > "$WORK/out.zst"
    run_in_terminal 'n
' "$T2SZ" -o "$WORK/out.zst" "$WORK/input.dat"
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — expected exit 0, got $RC"; exit 1; }
    content=$(cat "$WORK/out.zst")
    if [ "$content" != "SENTINEL" ]; then
        log_fail "$TEST_NAME — output file was overwritten despite answering 'n'"
        exit 1
    fi
    log_pass "$TEST_NAME"
    ;;

overwrite_yes)
    # Answering 'y' (or 'Y') to the overwrite prompt on a terminal must
    # replace the output file and return exit code 0.
    make_small_dat "$WORK/input.dat"
    printf 'x' > "$WORK/out.zst"    # 1-byte placeholder
    run_in_terminal 'y
' "$T2SZ" -o "$WORK/out.zst" "$WORK/input.dat"
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — expected exit 0, got $RC"; exit 1; }
    # A valid compressed output must be larger than the 1-byte placeholder.
    bytes=$(wc -c < "$WORK/out.zst")
    [ $((bytes + 0)) -gt 1 ] || {
        log_fail "$TEST_NAME — output file was not overwritten after answering 'y'"
        exit 1
    }
    printf 'x' > "$WORK/out.zst"
    run_in_terminal 'Y
' "$T2SZ" -o "$WORK/out.zst" "$WORK/input.dat"
    [ "$RC" -eq 0 ] && [ "$(wc -c < "$WORK/out.zst")" -gt 1 ] || {
        log_fail "$TEST_NAME — output file was not overwritten after answering 'Y' (exit $RC)"
        exit 1
    }
    # The rest of the answer must not end up in the archive: a FIFO given by
    # name is read through stdin once the prompt is over.
    head -c 5000 /dev/urandom > "$WORK/data.bin"
    mkfifo "$WORK/data.fifo"
    cat "$WORK/data.bin" > "$WORK/data.fifo" &
    writer=$!
    run_in_terminal 'yes
' "$T2SZ" -r -o "$WORK/out.zst" "$WORK/data.fifo"
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — FIFO input: expected exit 0, got $RC"; exit 1; }
    assert_roundtrip "$WORK/out.zst" "$WORK/data.bin"
    log_pass "$TEST_NAME"
    ;;

prompt_dev_stdin)
    # Input named /dev/stdin (a pipe here) and an existing output without -f:
    # the overwrite prompt takes its answer from the data being compressed.
    # Refusing is fine; exiting 0 with an output that is not the input is not.
    is_windows && { log_skip "$TEST_NAME — no /dev/stdin for native programs"; exit 77; }
    printf 'y' > "$WORK/input.bin"
    head -c 3000 /dev/urandom >> "$WORK/input.bin"
    printf 'SENTINEL' > "$WORK/out.zst"
    RC=0
    cat "$WORK/input.bin" | "$T2SZ" -r -o "$WORK/out.zst" /dev/stdin 2>/dev/null || RC=$?
    if [ "$RC" -eq 0 ]; then
        assert_roundtrip "$WORK/out.zst" "$WORK/input.bin"
    else
        assert_rc 1
        [ "$(cat "$WORK/out.zst")" = "SENTINEL" ] || { log_fail "$TEST_NAME — exit $RC but out.zst was modified"; exit 1; }
    fi
    log_pass "$TEST_NAME"
    ;;

prompt_eats_loop_input)
    # In a "while read" loop t2sz shares stdin with the loop: the overwrite
    # prompt for the first file swallows the rest of the list.
    make_small_dat "$WORK/a.dat"
    make_small_dat "$WORK/b.dat"
    printf 'SENTINEL' > "$WORK/a.dat.zst"
    printf '%s\n' "$WORK/a.dat" "$WORK/b.dat" | while read -r f; do
        "$T2SZ" -r "$f" 2>/dev/null
    done
    [ -f "$WORK/b.dat.zst" ] || {
        log_fail "$TEST_NAME — b.dat never compressed: the prompt consumed the loop input"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

prompt_eof)
    # No answer to the overwrite prompt (stdin at EOF, as under cron or CI):
    # nothing is written, yet t2sz exits 0.
    make_small_dat "$WORK/input.dat"
    printf 'SENTINEL' > "$WORK/out.zst"
    RC=0
    "$T2SZ" -r -o "$WORK/out.zst" "$WORK/input.dat" < /dev/null 2>/dev/null || RC=$?
    [ "$(cat "$WORK/out.zst")" = "SENTINEL" ] || { log_fail "$TEST_NAME — out.zst overwritten"; exit 1; }
    [ "$RC" -ne 0 ] || { log_fail "$TEST_NAME — exit 0 although nothing was written"; exit 1; }
    assert_rc 1
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

git_archive_checksum)
    # git archive, and so every GitHub source tarball, writes the header
    # checksum as 7 octal digits + NUL; isTarHeader() reads only 6 of them.
    command -v git >/dev/null 2>&1 || { log_skip "$TEST_NAME — git not found"; exit 77; }
    mkdir -p "$WORK/repo"
    printf 'hello from git archive\n' > "$WORK/repo/hello.txt"
    git -C "$WORK/repo" init -q && git -C "$WORK/repo" add hello.txt || {
        log_fail "$TEST_NAME — git setup failed"
        exit 1
    }
    tree=$(git -C "$WORK/repo" write-tree)
    git -C "$WORK/repo" archive --format=tar "$tree" > "$WORK/git.tar" || {
        log_fail "$TEST_NAME — git archive failed"
        exit 1
    }
    assert_exit 0  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/git.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/git.tar"
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
    # Each suffix of decodeMultiplier() stands for exactly its value: -s 1<suffix>
    # is accepted with -S of that value, and rejected (-S smaller than -s) with
    # one byte less. Covers every branch of decodeMultiplier().
    make_small_dat "$WORK/input.dat"
    for pair in k:1024 K:1024 KiB:1024 kB:1000 KB:1000 M:1048576 MiB:1048576 MB:1000000 \
                G:1073741824 GiB:1073741824 GB:1000000000; do
        suffix=${pair%%:*} value=${pair#*:}
        assert_exit 0  "$T2SZ" -r -s "1$suffix" -S "$value" -o "$WORK/out.zst" -f "$WORK/input.dat"
        assert_rejected -s "1$suffix" -S $(( value - 1 ))
    done
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

closed_stderr)
    # With stderr closed the output file gets descriptor 2, so every
    # message (here the -v listing) is written into the archive.
    make_small_tar "$WORK/input.tar"
    RC=0
    "$T2SZ" -v -f -o "$WORK/mmap.zst" "$WORK/input.tar" 2>&- || RC=$?
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — mmap path exited $RC"; exit 1; }
    assert_roundtrip "$WORK/mmap.zst" "$WORK/input.tar"
    RC=0
    "$T2SZ" -v -f -o "$WORK/stdin.zst" - < "$WORK/input.tar" 2>&- || RC=$?
    [ "$RC" -eq 0 ] || { log_fail "$TEST_NAME — stdin path exited $RC"; exit 1; }
    assert_roundtrip "$WORK/stdin.zst" "$WORK/input.tar"
    # Only stderr may be filled in: a closed stdin is no empty input. (A
    # Windows program started with stdin closed gets the NUL device.)
    if ! is_windows; then
        run "$T2SZ" -r -f -o "$WORK/closed.zst" - <&-
        [ "$RC" -ne 0 ] || { log_fail "$TEST_NAME — closed stdin compressed as an empty input, exit 0"; exit 1; }
        assert_rc 1
    fi
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

failed_run_leaves_output)
    # A run that fails half way leaves the frames written so far under the
    # final name: a valid zstd stream holding only part of the input.
    printf 'first\n' > "$WORK/a.txt"
    printf 'second\n' > "$WORK/b.txt"
    COPYFILE_DISABLE=1 tar --format=ustar -cf "$WORK/bad.tar" -C "$WORK" a.txt b.txt || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    # Corrupt the checksum of the second header (offset 1024).
    printf '\xff\xff\xff\xff\xff\xff\xff\xff' \
        | dd of="$WORK/bad.tar" bs=1 seek=$(( 1024 + 148 )) count=8 conv=notrunc 2>/dev/null
    assert_nonzero  "$T2SZ" -o "$WORK/out.zst" "$WORK/bad.tar"
    [ ! -e "$WORK/out.zst" ] || {
        log_fail "$TEST_NAME — failed run left out.zst ($(wc -c < "$WORK/out.zst" | tr -d ' ') bytes)"
        exit 1
    }
    # Only a regular file is removed: removing an output that is a symbolic
    # link would remove the link, not its target (Windows: no lstat()).
    if ! is_windows && ln -s target.zst "$WORK/link.zst" && [ -L "$WORK/link.zst" ]; then
        assert_nonzero  "$T2SZ" -f -o "$WORK/link.zst" "$WORK/bad.tar"
        [ -L "$WORK/link.zst" ] || { log_fail "$TEST_NAME — failed run removed the symbolic link link.zst"; exit 1; }
    fi
    # A run ended by a signal (Ctrl-C, kill) removes its output too: here
    # SIGTERM, while t2sz waits for more input from a FIFO.
    if ! is_windows; then
        mkfifo "$WORK/in.fifo"
        "$T2SZ" -r -f -o "$WORK/killed.zst" - < "$WORK/in.fifo" 2>/dev/null &
        pid=$!
        exec 3> "$WORK/in.fifo"
        printf 'partial input' >&3
        n=0
        while [ ! -e "$WORK/killed.zst" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
        kill -TERM "$pid"
        wait "$pid"
        exec 3>&-
        [ ! -e "$WORK/killed.zst" ] || { log_fail "$TEST_NAME — run ended by SIGTERM left killed.zst"; exit 1; }
    fi
    log_pass "$TEST_NAME"
    ;;

stdin_empty_tar)
    # Empty tar (tar with zero-byte file) via stdin — exercises isZeroTarBlock().
    # Like the mmap empty_tar test it must compress and round-trip.
    touch "$WORK/empty"
    (cd "$WORK" && COPYFILE_DISABLE=1 tar cf empty.tar empty) || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    assert_exit 0  "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/empty.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/empty.tar"
    log_pass "$TEST_NAME"
    ;;

one_frame_per_file)
    # Besides pax 'x' and GNU 'L' headers, these entries got frames of their
    # own: the pax global header ('g') that git archive writes first, the
    # AppleDouble file ("._name") that macOS tar writes before a file with
    # extended attributes, and each null block at the end of the archive
    # (18 or more from GNU tar). From stdin, a frame that started with an
    # extended header did not know its size.
    longname=$(printf 'n%.0s' {1..150})
    mkdir -p "$WORK/src"
    printf '16 comment=t2sz\n' > "$WORK/src/pax_global_header"
    printf 'T2SZ-LONG\n' > "$WORK/src/$longname"
    printf 'T2SZ-APPLEDOUBLE\n' > "$WORK/src/._b.txt"
    printf 'T2SZ-B\n' > "$WORK/src/b.txt"
    COPYFILE_DISABLE=1 tar --format=pax -cf "$WORK/input.tar" -C "$WORK/src" pax_global_header "$longname" ._b.txt b.txt || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    # Make the first file the global header that git archive writes.
    off=$(grep -abo pax_global_header "$WORK/input.tar" | awk -F: '$1 % 512 == 0 { print $1; exit }')
    set_tar_typeflag "$WORK/input.tar" "$off" g
    head -c 8192 /dev/zero >> "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -o "$WORK/file.zst" -f "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -o "$WORK/stdin.zst" -f - < "$WORK/input.tar"
    for src in file stdin; do
        assert_roundtrip "$WORK/$src.zst" "$WORK/input.tar"
        sizes=$(seek_table_entries "$WORK/$src.zst" | awk '{ printf "%s ", $2 }')
        [ "$(seek_table_frames "$WORK/$src.zst")" -eq 3 ] || {
            log_fail "$TEST_NAME — $src: frames of $sizes bytes, not one for each of the two files and one for the end blocks"
            exit 1
        }
    done
    a=$(frame_descriptors "$WORK/file.zst")
    b=$(frame_descriptors "$WORK/stdin.zst")
    [ "$a" = "$b" ] || {
        log_fail "$TEST_NAME — frame header descriptors $b from stdin, $a from the file"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

pax_header_own_frame)
    # A pax extended header ('x') or a GNU long name ('L') describes the
    # entry after it, but t2sz put it in a frame of its own: the frame of
    # the file lacked its real name.
    longname=$(printf 'n%.0s' {1..150})
    mkdir -p "$WORK/src"
    printf 'T2SZ-PAYLOAD\n' > "$WORK/src/$longname"
    for fmt in pax gnu; do
        flags="--format=$fmt"
        if ! tar --version 2>/dev/null | grep -q 'GNU tar'; then
            [ "$fmt" = gnu ] && flags="--format=gnutar"    # bsdtar
        fi
        COPYFILE_DISABLE=1 tar $flags -cf "$WORK/input.tar" -C "$WORK/src" "$longname" || {
            log_fail "$TEST_NAME — tar creation failed ($flags)"
            exit 1
        }
        assert_exit 0  "$T2SZ" -o "$WORK/file.zst" -f "$WORK/input.tar"
        assert_exit 0  "$T2SZ" -o "$WORK/stdin.zst" -f - < "$WORK/input.tar"
        for src in file stdin; do
            assert_roundtrip "$WORK/$src.zst" "$WORK/input.tar"
            c0=$(seek_table_entry "$WORK/$src.zst" 0 0)
            head -c "$c0" "$WORK/$src.zst" | zstd -d -c -q > "$WORK/frame0.bin" 2>/dev/null
            grep -q T2SZ-PAYLOAD "$WORK/frame0.bin" || {
                log_fail "$TEST_NAME — $fmt, $src: frame 0 holds only the header before the file ($(wc -c < "$WORK/frame0.bin" | tr -d ' ') bytes)"
                exit 1
            }
        done
    done
    log_pass "$TEST_NAME"
    ;;

stdin_truncated_tar)
    # Partial 512-byte header on stdin → "Truncated tar header" error.
    # Send exactly 256 zero bytes: fread returns 256, r != 512 triggers the error.
    dd if=/dev/zero of="$WORK/partial.bin" bs=1 count=256 2>/dev/null
    assert_nonzero "$T2SZ" -o "$WORK/out.zst" -f - < "$WORK/partial.bin"
    log_pass "$TEST_NAME"
    ;;

partial_tail_block)
    # Bytes after the last complete 512-byte block (a cut archive, or bytes
    # appended to it) are left out of the output with exit 0.
    # Refusing the input (exit 1) is fine; dropping bytes silently is not.
    make_small_tar "$WORK/good.tar"
    cp "$WORK/good.tar" "$WORK/tail.tar"
    head -c 100 /dev/urandom >> "$WORK/tail.tar"
    RC=0
    "$T2SZ" -o "$WORK/mmap.zst" -f "$WORK/tail.tar" 2>/dev/null || RC=$?
    if [ "$RC" -eq 0 ]; then assert_roundtrip "$WORK/mmap.zst" "$WORK/tail.tar"; else assert_rc 1; fi
    RC=0
    "$T2SZ" -o "$WORK/stdin.zst" -f - < "$WORK/tail.tar" 2>/dev/null || RC=$?
    if [ "$RC" -eq 0 ]; then assert_roundtrip "$WORK/stdin.zst" "$WORK/tail.tar"; else assert_rc 1; fi
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

noseek_tar)
    # -j in tar mode: with the seek table off no frame is counted, and the
    # "no tar entries" check turns a complete run into exit 1.
    make_small_tar "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -j -o "$WORK/mmap.zst" -f "$WORK/input.tar"
    assert_roundtrip "$WORK/mmap.zst" "$WORK/input.tar"
    verify_no_seek_table "$WORK/mmap.zst" || exit 1
    assert_exit 0  "$T2SZ" -j -o "$WORK/stdin.zst" -f - < "$WORK/input.tar"
    assert_roundtrip "$WORK/stdin.zst" "$WORK/input.tar"
    verify_no_seek_table "$WORK/stdin.zst" || exit 1
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
    verify_seek_table "$WORK/out.zst" 4 1000001 || exit 1
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
    verify_seek_table "$WORK/out.zst" 4 1000001 || exit 1
    log_pass "$TEST_NAME"
    ;;

maxblock_null_blocks)
    # -S is the maximum frame size, but the mmap path adds end-of-archive
    # blocks to a frame without checking it.
    make_small_tar "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -s 1000 -S 1000 -o "$WORK/file.zst" -f "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -s 1000 -S 1000 -o "$WORK/stdin.zst" -f - < "$WORK/input.tar"
    for src in file stdin; do
        assert_roundtrip "$WORK/$src.zst" "$WORK/input.tar"
        max=$(seek_table_entries "$WORK/$src.zst" | awk '$2 > m { m = $2 } END { print m + 0 }')
        [ "$max" -le 1000 ] || {
            log_fail "$TEST_NAME — $src: a frame holds $max bytes, more than -S 1000"
            exit 1
        }
    done
    log_pass "$TEST_NAME"
    ;;

# ── Tar trailing junk after end-of-archive ──────────────────────────────────

trailing_junk_tar)
    # Create a valid tar, then append 1024 bytes of non-zero junk (0xAA) after
    # the end-of-archive blocks. Both mmap and stdin paths read until EOF, so
    # both will encounter the junk, fail isTarHeader(), and exit 1 (a crash,
    # or a sanitizer error, would exit otherwise).
    make_small_tar "$WORK/good.tar"
    cp "$WORK/good.tar" "$WORK/junk.tar"
    dd if=/dev/zero bs=1 count=1024 2>/dev/null | tr '\0' '\252' >> "$WORK/junk.tar"

    RC=0
    "$T2SZ" -o "$WORK/out_mmap.zst" -f "$WORK/junk.tar" 2>/dev/null || RC=$?
    assert_rc 1
    RC=0
    "$T2SZ" -o "$WORK/out_stdin.zst" -f - < "$WORK/junk.tar" 2>/dev/null || RC=$?
    assert_rc 1

    log_pass "$TEST_NAME"
    ;;

maxblock_no_eoa)
    # A tar without the end-of-archive blocks whose last entry is larger than
    # -S: the mmap loop stops when the parser reaches the end of the input,
    # while the rest of the entry (the residual) is still waiting to be
    # compressed. Exit 0, data lost.
    head -c 5000 /dev/urandom > "$WORK/data.bin"
    COPYFILE_DISABLE=1 tar --format=ustar -cf "$WORK/full.tar" -C "$WORK" data.bin || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    head -c $(( 512 + 5120 )) "$WORK/full.tar" > "$WORK/noeoa.tar"   # header + padded payload
    assert_exit 0  "$T2SZ" -S 1k -o "$WORK/mmap.zst" -f "$WORK/noeoa.tar"
    assert_roundtrip "$WORK/mmap.zst" "$WORK/noeoa.tar"
    assert_exit 0  "$T2SZ" -S 1k -o "$WORK/stdin.zst" -f - < "$WORK/noeoa.tar"
    assert_roundtrip "$WORK/stdin.zst" "$WORK/noeoa.tar"
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

gnu_sparse_extended)
    # GNU tar --sparse (gnu format) with more than 4 data segments keeps the
    # rest of the sparse map in extension blocks after the header. t2sz does
    # not skip them, so it looks for the next header inside the payload
    # (random data here, so it cannot pass for an end-of-archive block).
    GTAR=""
    for t in gtar tar; do
        if command -v "$t" >/dev/null 2>&1 && "$t" --version 2>/dev/null | grep -q 'GNU tar'; then
            GTAR="$t"
            break
        fi
    done
    [ -n "$GTAR" ] || { log_skip "$TEST_NAME — GNU tar not found"; exit 77; }
    make_sparse "$WORK/sparse.bin" $(( 6 * 1048576 ))
    head -c 4096 /dev/urandom > "$WORK/segment.bin"
    for i in 0 1 2 3 4 5; do
        dd if="$WORK/segment.bin" of="$WORK/sparse.bin" bs=4096 seek=$(( i * 256 )) conv=notrunc 2>/dev/null
    done
    "$GTAR" --sparse --format=gnu -cf "$WORK/sparse.tar" -C "$WORK" sparse.bin || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    # typeflag 'S' (83) with the isextended flag (offset 482) set
    if [ "$(read_byte "$WORK/sparse.tar" 156)" -ne 83 ] || [ "$(read_byte "$WORK/sparse.tar" 482)" -ne 1 ]; then
        log_skip "$TEST_NAME — $GTAR wrote no sparse entry with extension blocks"
        exit 77
    fi
    assert_exit 0  "$T2SZ" -o "$WORK/out.zst" -f "$WORK/sparse.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/sparse.tar"
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

fifo_input)
    # A path that is a pipe (a FIFO, or a process substitution like <(...))
    # cannot be mapped, so t2sz streams it. A name without .tar means raw
    # mode, one frame; read as '-' (t2sz - < fifo, as the help says) the same
    # stream is compressed as a tar, with the frames it gets from a file.
    is_windows && { log_skip "$TEST_NAME — native Windows programs cannot open MSYS2 FIFOs"; exit 77; }
    make_small_tar "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -f -o "$WORK/file.zst" "$WORK/input.tar"
    mkfifo "$WORK/fifo" || { log_fail "$TEST_NAME — mkfifo failed"; exit 1; }
    # If t2sz never opened the FIFO, the writer would stay blocked in open():
    # stop it in any case, so that the test fails instead of hanging.
    cat "$WORK/input.tar" > "$WORK/fifo" &
    writer=$!
    run "$T2SZ" -f -o "$WORK/fifo.zst" "$WORK/fifo"
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null
    assert_rc 0
    assert_exit 0  "$T2SZ" -f -o "$WORK/procsub.zst" <(cat "$WORK/input.tar")
    assert_exit 0  "$T2SZ" -f -o "$WORK/stdin.zst" - < <(cat "$WORK/input.tar")
    for src in fifo procsub stdin; do
        assert_roundtrip "$WORK/$src.zst" "$WORK/input.tar"
    done
    [ "$(seek_table_frames "$WORK/fifo.zst")" -eq 1 ] && [ "$(seek_table_frames "$WORK/procsub.zst")" -eq 1 ] || {
        log_fail "$TEST_NAME — a pipe named without .tar was not compressed in raw mode"
        exit 1
    }
    [ "$(seek_table_frames "$WORK/stdin.zst")" -eq "$(seek_table_frames "$WORK/file.zst")" ] || {
        log_fail "$TEST_NAME — $(seek_table_frames "$WORK/stdin.zst") frames through '-', $(seek_table_frames "$WORK/file.zst") from the file"
        exit 1
    }
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

stdin_frame_header)
    # From stdin every frame started with an unknown pledged size: no content
    # size in the frame header, and zstd sizes window and tables for an
    # unbounded input (about 700 MiB of RAM at -l 22 for a tiny archive).
    # Without -s each entry has a frame of its own, whose size is known. The
    # archive is ustar, with no extended header (see one_frame_per_file).
    printf 'hello t2sz error tests\n' > "$WORK/hello.txt"
    COPYFILE_DISABLE=1 tar --format=ustar -cf "$WORK/input.tar" -C "$WORK" hello.txt || {
        log_fail "$TEST_NAME — tar creation failed"
        exit 1
    }
    assert_exit 0  "$T2SZ" -o "$WORK/file.zst" -f "$WORK/input.tar"
    assert_exit 0  "$T2SZ" -o "$WORK/stdin.zst" -f - < "$WORK/input.tar"
    assert_roundtrip "$WORK/stdin.zst" "$WORK/input.tar"
    a=$(read_byte "$WORK/file.zst" 4)    # Frame_Header_Descriptor of frame 0
    b=$(read_byte "$WORK/stdin.zst" 4)
    [ "$a" -eq "$b" ] || {
        log_fail "$TEST_NAME — frame header descriptor $(printf 0x%02x "$b") from stdin, $(printf 0x%02x "$a") from the file"
        exit 1
    }
    log_pass "$TEST_NAME"
    ;;

# ── Argument parsing edge cases: strtol failures ────────────────────────────

bad_level_strtol)
    # Exercises strtol() edge cases in -l argument parsing:
    #   endptr == optarg (non-numeric), *endptr != '\0' (trailing garbage),
    #   ERANGE (overflow beyond LONG_MAX), negative value.
    assert_rejected -l abc
    assert_rejected -l 3abc
    assert_rejected -l 99999999999999999999
    assert_rejected -l -1
    log_pass "$TEST_NAME"
    ;;

bad_block_s_strtol)
    # Exercises strtol() edge cases in -s argument parsing:
    #   endptr == optarg (non-numeric), trailing garbage (unrecognized suffix),
    #   ERANGE (overflow), negative value.
    assert_rejected -s abc
    assert_rejected -s 2abc
    assert_rejected -s 99999999999999999999
    assert_rejected -s -1
    log_pass "$TEST_NAME"
    ;;

bad_block_S_strtol)
    # Exercises strtol() edge cases in -S argument parsing:
    #   endptr == optarg (non-numeric), trailing garbage (unrecognized suffix),
    #   ERANGE (overflow), negative value.
    assert_rejected -S abc
    assert_rejected -S 2abc
    assert_rejected -S 99999999999999999999
    assert_rejected -S -1
    log_pass "$TEST_NAME"
    ;;

bad_threads_strtol)
    # Exercises strtol() edge cases in -T argument parsing:
    #   endptr == optarg (non-numeric), *endptr != '\0' (trailing garbage),
    #   ERANGE (overflow beyond LONG_MAX), val > UINT32_MAX, negative value.
    assert_rejected -T abc
    assert_rejected -T 2abc
    assert_rejected -T 99999999999999999999
    assert_rejected -T 4294967296
    assert_rejected -T -1
    log_pass "$TEST_NAME"
    ;;

# ── Unknown option — getopt '?' → switch default case ──────────────────────

unknown_option)
    # Unrecognized option -Z triggers getopt '?' → switch default case.
    # usage(executable, "ERROR: Unknown option") exits with EXIT_FAILURE (1).
    assert_rejected -Z
    log_pass "$TEST_NAME"
    ;;

ustar_size_over_4gib)
    # A member between 4 and 8 GiB has a plain octal size, but strtoul()
    # returns an unsigned long, 32-bit on Windows and on 32-bit systems.
    check_disk_space "$BLOBS_DIR" 10 || { log_skip "$TEST_NAME — needs 10 GB free"; exit 77; }
    make_big_member_tar ustar 4294967297 "$WORK/big.tar"
    assert_exit 0  "$T2SZ" -S 1G -o "$WORK/out.zst" -f "$WORK/big.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/big.tar"
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

pax_size)
    # A member of 8 GiB or more in pax format: the real size is in the
    # extended header, which t2sz ignores.
    check_disk_space "$BLOBS_DIR" 10 || { log_skip "$TEST_NAME — needs 10 GB free"; exit 77; }
    make_big_member_tar pax 8589934593 "$WORK/big.tar"
    assert_exit 0  "$T2SZ" -S 1G -o "$WORK/out.zst" -f "$WORK/big.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/big.tar"
    log_pass "$TEST_NAME"
    ;;

# ── Stdin overwrite protection ────────────────────────────────────────────

stdin_overwrite_no_force)
    # Piping data through stdin with an existing output file and no -f flag.
    # An interactive prompt would corrupt the pipe, so t2sz must refuse with
    # a clear error message and exit 1 instead of prompting.
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
    assert_rejected -s 999999999999GiB
    log_pass "$TEST_NAME"
    ;;

overflow_S)
    # Same overflow guard for case 'S' (maxBlockSize).
    assert_rejected -S 999999999999GiB
    log_pass "$TEST_NAME"
    ;;

base256_size)
    # A member of 8 GiB or more: GNU tar and bsdtar (gnu format) store its
    # size in base-256, which parseTarSize() reads as octal.
    check_disk_space "$BLOBS_DIR" 10 || { log_skip "$TEST_NAME — needs 10 GB free"; exit 77; }
    make_big_member_tar gnu 8589934593 "$WORK/big.tar"
    [ "$(read_byte "$WORK/big.tar" 124)" -eq 128 ] || { log_skip "$TEST_NAME — tar did not write a base-256 size"; exit 77; }
    assert_exit 0  "$T2SZ" -S 1G -o "$WORK/out.zst" -f "$WORK/big.tar"
    assert_roundtrip "$WORK/out.zst" "$WORK/big.tar"
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
    verify_seek_table "$WORK/out.zst" 1025 1049600 || exit 1
    log_pass "$TEST_NAME"
    ;;

# ── Garbage between number and suffix in -s/-S ──────────────────────────────

garbage_suffix)
    # Exercises the decodeMultiplier() fix: garbage characters between the
    # numeric value and a valid suffix (e.g. "1xyzGiB") must be rejected.
    # Before the fix, strEndsWith() would match the trailing "GiB" and
    # silently accept the argument.
    assert_rejected -s 1xyzGiB
    assert_rejected -S 1xyzGiB
    assert_rejected -s 10fooM
    assert_rejected -S 10fooM
    assert_rejected -s 5barKiB
    assert_rejected -S 5barKiB
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
