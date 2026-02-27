#!/usr/bin/env bash
# test_roundtrip.sh — Round-trip integration test for t2sz
#
# Called by CTest via tests/CMakeLists.txt add_roundtrip_test().
#
# Usage:
#   test_roundtrip.sh T2SZ GEN_BLOB BLOBS_DIR MODE SEED SIZE N_FILES [T2SZ_FLAGS...]
#
# Arguments:
#   T2SZ       path to the t2sz binary under test
#   GEN_BLOB   path to the gen_blob binary
#   BLOBS_DIR  directory where temporary test files are written
#   MODE       raw | tar | empty_tar
#   SEED       integer seed for gen_blob (deterministic output)
#   SIZE       size in bytes of each generated blob
#   N_FILES    number of blobs (relevant for 'tar' mode; use 1 for 'raw')
#   T2SZ_FLAGS any additional flags forwarded verbatim to t2sz
#
# Exit codes:
#   0  test passed
#   1  test failed
#   77 test skipped (insufficient disk space — CTest SKIP_RETURN_CODE)

set -eo pipefail

# ── Bootstrap ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/helpers.sh"

T2SZ="$1"
GEN_BLOB="$2"
BLOBS_DIR="$3"
MODE="$4"
SEED="$5"
SIZE="$6"
N_FILES="$7"
shift 7
# All remaining args are T2SZ_FLAGS (may be empty)

die()  { printf "[ERROR] %s\n" "$*" >&2; exit 1; }

FLAGS_LABEL="$([ $# -gt 0 ] && echo "$*" || echo "none")"
LABEL="mode=$MODE seed=$SEED size=$SIZE n=$N_FILES flags=$FLAGS_LABEL"

# ── Disk-space guard (skip large tests when space is tight) ──────────────────
# Estimate: need roughly SIZE * N_FILES * 3 (original + compressed + decompressed)
NEEDED_GB=$(( (SIZE * N_FILES * 3) / 1073741824 ))
if [ "$NEEDED_GB" -ge 1 ] && ! check_disk_space "$BLOBS_DIR" "$((NEEDED_GB + 1))"; then
    log_skip "$LABEL — need ~${NEEDED_GB}GB free, skipping"
    exit 77
fi

# ── Unique working directory for this test run ────────────────────────────────
WORK="$BLOBS_DIR/${MODE}_${SEED}_${SIZE}_${N_FILES}_$$"
mkdir -p "$WORK"
trap '[ "${KEEP_BLOBS:-0}" = "0" ] && rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# RAW MODE
# Generates one blob, compresses it with -r, decompresses, checks SHA-256.
# ═══════════════════════════════════════════════════════════════════════════════
test_raw() {
    local input="$WORK/input.bin"
    local compressed="$WORK/input.bin.zst"
    local decompressed="$WORK/input.bin.dec"

    log_step "Generating blob (seed=$SEED size=$SIZE)"
    "$GEN_BLOB" "$SEED" "$SIZE" "$input" || die "gen_blob failed"

    local sha_before
    sha_before=$(sha256_file "$input")

    log_step "Compressing with t2sz -r $*"
    "$T2SZ" -r -o "$compressed" -f "$@" "$input" \
        || die "t2sz exited with $? — command: t2sz -r -o $compressed -f $* $input"

    log_step "Decompressing with zstd"
    zstd -d -f -q "$compressed" -o "$decompressed" \
        || die "zstd decompression failed"

    local sha_after
    sha_after=$(sha256_file "$decompressed")

    if [ "$sha_before" = "$sha_after" ]; then
        log_pass "$LABEL"
    else
        log_fail "$LABEL"
        log_info "SHA256 before: $sha_before"
        log_info "SHA256 after:  $sha_after"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TAR MODE
# Generates N_FILES blobs, packs them into a tar, compresses, decompresses,
# extracts, and verifies each file's SHA-256.
# ═══════════════════════════════════════════════════════════════════════════════
test_tar() {
    local archive="$WORK/archive.tar"
    local compressed="$WORK/archive.tar.zst"
    local dec_tar="$WORK/archive_dec.tar"
    local extract="$WORK/extracted"
    mkdir -p "$extract"

    # Generate blobs and save their expected SHA-256 hashes to sidecar files.
    # (Avoids bash 4 associative arrays — compatible with bash 3.2 on macOS.)
    local blob_list=()
    local i
    for i in $(seq 1 "$N_FILES"); do
        local bseed=$(( SEED * 1000 + i ))
        local bname="blob_${bseed}.bin"
        local bpath="$WORK/$bname"

        log_step "Generating $bname (seed=$bseed size=$SIZE)"
        "$GEN_BLOB" "$bseed" "$SIZE" "$bpath" || die "gen_blob failed for file $i"

        sha256_file "$bpath" > "$WORK/sha_${bname}.txt"
        blob_list+=("$bname")
    done

    # Build tar (relative paths so extraction is clean)
    log_step "Creating tar with ${#blob_list[@]} file(s)"
    (cd "$WORK" && tar cf archive.tar "${blob_list[@]}") \
        || die "tar creation failed"

    log_step "Compressing with t2sz $*"
    "$T2SZ" -o "$compressed" -f "$@" "$archive" \
        || die "t2sz exited with $? — command: t2sz -o $compressed -f $* $archive"

    log_step "Decompressing with zstd"
    zstd -d -f -q "$compressed" -o "$dec_tar" \
        || die "zstd decompression failed"

    log_step "Extracting tar"
    tar xf "$dec_tar" -C "$extract" \
        || die "tar extraction failed"

    # Verify every blob
    local all_ok=true
    for bname in "${blob_list[@]}"; do
        local expected actual
        expected=$(cat "$WORK/sha_${bname}.txt")
        actual=$(sha256_file "$extract/$bname")
        if [ "$expected" != "$actual" ]; then
            log_fail "$LABEL — SHA256 mismatch for $bname"
            log_info "  expected: $expected"
            log_info "  actual:   $actual"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "$LABEL"
    else
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# EMPTY TAR EDGE CASE
# Creates a tar containing a single zero-byte file. Verifies that t2sz:
#   • does not segfault / receive a fatal signal
#   • ASAN reports no violations (checked by CTest via exit code)
# A non-zero exit from t2sz is tolerated and documented as expected behaviour.
# ═══════════════════════════════════════════════════════════════════════════════
test_empty_tar() {
    local empty_file="$WORK/empty"
    local archive="$WORK/empty.tar"
    local compressed="$WORK/empty.tar.zst"

    touch "$empty_file"
    (cd "$WORK" && tar cf empty.tar empty) \
        || die "tar creation failed"

    log_step "Compressing empty tar with t2sz $*"
    local rc=0
    "$T2SZ" -o "$compressed" -f "$@" "$archive" || rc=$?

    if [ "$rc" -eq 0 ]; then
        log_pass "$LABEL — exited 0, no crash"
    else
        # A non-zero exit is acceptable; what matters is no signal (>128 = signal)
        if [ "$rc" -gt 128 ]; then
            log_fail "$LABEL — killed by signal $(( rc - 128 ))"
            exit 1
        else
            log_pass "$LABEL — exited $rc (non-zero, no crash — documented behaviour)"
        fi
    fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$MODE" in
    raw)       test_raw       "$@" ;;
    tar)       test_tar       "$@" ;;
    empty_tar) test_empty_tar "$@" ;;
    *)         die "Unknown test mode: '$MODE'. Valid: raw | tar | empty_tar" ;;
esac
