#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# helpers.sh — Shared utilities for the t2sz test suite
#
# Source this file from other test scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/helpers.sh"

# ── Platform detection ────────────────────────────────────────────────────────
OS="$(uname -s)"

case "$OS" in
    Darwin)
        SHA256CMD="shasum -a 256"
        ;;
    Linux|*)
        SHA256CMD="sha256sum"
        ;;
esac

# ── Terminal colours (only when stdout is a tty) ──────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' NC=''
fi

# ── Counters (global, accumulated across all calls in a process) ──────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { printf "${GREEN}[PASS]${NC} %s\n" "$*"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_skip() { printf "${YELLOW}[SKIP]${NC} %s\n" "$*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
log_info() { printf "       %s\n" "$*"; }
log_step() { printf "${CYAN}  →${NC} %s\n" "$*"; }

# ── sha256_file <path> ────────────────────────────────────────────────────────
# Prints just the hex hash string (no filename).
sha256_file() {
    $SHA256CMD "$1" | awk '{print $1}'
}

# ── check_disk_space <path> <required_gb> ────────────────────────────────────
# Returns 0 if at least <required_gb> GB are available at <path>, 1 otherwise.
check_disk_space() {
    local path="$1"
    local required_gb="$2"
    local available_kb
    available_kb=$(df -k "$path" | awk 'NR==2 {print $4}')
    local required_kb=$(( required_gb * 1024 * 1024 ))
    [ "$available_kb" -ge "$required_kb" ]
}

# ── print_summary ─────────────────────────────────────────────────────────────
# Prints a final count and returns 1 if any test failed.
print_summary() {
    echo ""
    printf "%-40s\n" "════════════════════════════════════════"
    printf "  ${GREEN}%d passed${NC}  ${RED}%d failed${NC}  ${YELLOW}%d skipped${NC}\n" \
        "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
    printf "%-40s\n" "════════════════════════════════════════"
    [ "$FAIL_COUNT" -eq 0 ]
}

# ── decode_size_arg <SIZE_WITH_SUFFIX> ──────────────────────────────────────
# Parses a size argument like "256k", "1M", "512" into a byte count.
# Mirrors the decodeMultiplier() logic in t2sz.c.
decode_size_arg() {
    local arg="$1" num mult=1
    case "$arg" in
        *GiB) num="${arg%GiB}"; mult=$((1024*1024*1024)) ;;
        *MiB) num="${arg%MiB}"; mult=$((1024*1024)) ;;
        *KiB) num="${arg%KiB}"; mult=1024 ;;
        *GB)  num="${arg%GB}";  mult=$((1000*1000*1000)) ;;
        *MB)  num="${arg%MB}";  mult=$((1000*1000)) ;;
        *KB)  num="${arg%KB}";  mult=1000 ;;
        *kB)  num="${arg%kB}";  mult=1000 ;;
        *G)   num="${arg%G}";   mult=$((1024*1024*1024)) ;;
        *M)   num="${arg%M}";   mult=$((1024*1024)) ;;
        *k|*K) num="${arg%[kK]}"; mult=1024 ;;
        *)    num="$arg" ;;
    esac
    echo $(( num * mult ))
}

# ── read_le32 <file> <byte_offset> ─────────────────────────────────────────
# Reads 4 bytes at the given offset and reconstructs a little-endian uint32.
# Uses POSIX od(1) — available on both macOS and Linux.
read_le32() {
    local file="$1" offset="$2"
    local b
    b=( $(od -A n -t u1 -j "$offset" -N 4 "$file") )
    echo $(( b[0] + b[1]*256 + b[2]*65536 + b[3]*16777216 ))
}

# ── read_byte <file> <byte_offset> ─────────────────────────────────────────
# Reads a single byte at the given offset as an unsigned decimal value.
read_byte() {
    local file="$1" offset="$2"
    local b
    b=( $(od -A n -t u1 -j "$offset" -N 1 "$file") )
    echo "${b[0]}"
}

# ── verify_seek_table <file> <expected_frames> ─────────────────────────────
# Reads the seek table at the tail of a seekable-zstd file and verifies:
#   1. Seekable magic (0x8F92EAB1 = 2408770225) in the last 4 bytes
#   2. Descriptor byte is 0x00
#   3. Number_Of_Frames matches expected_frames
#   4. Skippable magic (0x184D2A5E = 407710302) at the start of the skippable frame
#   5. Frame_Size field == (N * 8) + 9
# Returns 0 on success, 1 on failure (logs the mismatch).
verify_seek_table() {
    local file="$1"
    local expected_frames="$2"
    local file_size

    file_size=$(wc -c < "$file")
    file_size=$((file_size + 0))  # strip whitespace

    local seek_table_size=$(( expected_frames * 8 + 17 ))

    if [ "$file_size" -lt "$seek_table_size" ]; then
        log_fail "verify_seek_table: file too small ($file_size < $seek_table_size)"
        return 1
    fi

    # ── Footer (last 9 bytes): Number_Of_Frames(4) + Descriptor(1) + Seekable_Magic(4) ──
    local footer_offset=$(( file_size - 9 ))

    local seekable_magic
    seekable_magic=$(read_le32 "$file" $(( file_size - 4 )))
    if [ "$seekable_magic" -ne 2408770225 ]; then
        log_fail "verify_seek_table: bad seekable magic (got $seekable_magic, expected 2408770225/0x8F92EAB1)"
        return 1
    fi

    local descriptor
    descriptor=$(read_byte "$file" $(( file_size - 5 )))
    if [ "$descriptor" -ne 0 ]; then
        log_fail "verify_seek_table: bad descriptor byte (got $descriptor, expected 0)"
        return 1
    fi

    local num_frames
    num_frames=$(read_le32 "$file" "$footer_offset")
    if [ "$num_frames" -ne "$expected_frames" ]; then
        log_fail "verify_seek_table: frame count mismatch (got $num_frames, expected $expected_frames)"
        return 1
    fi

    # ── Skippable frame header (first 8 bytes of seek table) ──
    local header_offset=$(( file_size - seek_table_size ))

    local skip_magic
    skip_magic=$(read_le32 "$file" "$header_offset")
    # 0x184D2A5E = 407710302
    if [ "$skip_magic" -ne 407710302 ]; then
        log_fail "verify_seek_table: bad skippable magic (got $skip_magic, expected 407710302/0x184D2A5E)"
        return 1
    fi

    local frame_size_field
    frame_size_field=$(read_le32 "$file" $(( header_offset + 4 )))
    local expected_frame_size=$(( expected_frames * 8 + 9 ))
    if [ "$frame_size_field" -ne "$expected_frame_size" ]; then
        log_fail "verify_seek_table: Frame_Size mismatch (got $frame_size_field, expected $expected_frame_size)"
        return 1
    fi

    return 0
}

# ── verify_seek_table_structure <file> ──────────────────────────────────────
# Like verify_seek_table but without an expected frame count.
# Verifies only internal consistency: magic numbers, descriptor, Frame_Size == N*8+9.
# Use for tests where the exact frame count is hard to predict (e.g. tar with -s/-S).
verify_seek_table_structure() {
    local file="$1"
    local file_size

    file_size=$(wc -c < "$file")
    file_size=$((file_size + 0))

    if [ "$file_size" -lt 17 ]; then
        log_fail "verify_seek_table_structure: file too small to contain a seek table"
        return 1
    fi

    # Seekable magic (last 4 bytes)
    local seekable_magic
    seekable_magic=$(read_le32 "$file" $(( file_size - 4 )))
    if [ "$seekable_magic" -ne 2408770225 ]; then
        log_fail "verify_seek_table_structure: bad seekable magic (got $seekable_magic)"
        return 1
    fi

    # Descriptor (1 byte before seekable magic)
    local descriptor
    descriptor=$(read_byte "$file" $(( file_size - 5 )))
    if [ "$descriptor" -ne 0 ]; then
        log_fail "verify_seek_table_structure: bad descriptor (got $descriptor)"
        return 1
    fi

    # Number_Of_Frames (4 bytes before descriptor)
    local num_frames
    num_frames=$(read_le32 "$file" $(( file_size - 9 )))

    # Verify skippable frame header
    local seek_table_size=$(( num_frames * 8 + 17 ))
    if [ "$file_size" -lt "$seek_table_size" ]; then
        log_fail "verify_seek_table_structure: file too small for $num_frames frames"
        return 1
    fi

    local header_offset=$(( file_size - seek_table_size ))

    local skip_magic
    skip_magic=$(read_le32 "$file" "$header_offset")
    if [ "$skip_magic" -ne 407710302 ]; then
        log_fail "verify_seek_table_structure: bad skippable magic (got $skip_magic)"
        return 1
    fi

    local frame_size_field
    frame_size_field=$(read_le32 "$file" $(( header_offset + 4 )))
    local expected_frame_size=$(( num_frames * 8 + 9 ))
    if [ "$frame_size_field" -ne "$expected_frame_size" ]; then
        log_fail "verify_seek_table_structure: Frame_Size mismatch (got $frame_size_field, expected $expected_frame_size)"
        return 1
    fi

    return 0
}

# ── verify_no_seek_table <file> ─────────────────────────────────────────────
# Verifies that the seekable-zstd magic (0x8F92EAB1) does NOT appear
# in the last 4 bytes of the file. Used to validate -j (no seek table)
# and -j flag (skip seek table). Note: stdout mode DOES write the seek table
# (it is appended, no seeking needed), so this function is not for stdout checks.
verify_no_seek_table() {
    local file="$1"
    local file_size

    file_size=$(wc -c < "$file")
    file_size=$((file_size + 0))

    if [ "$file_size" -lt 4 ]; then
        return 0
    fi

    local magic
    magic=$(read_le32 "$file" $(( file_size - 4 )))
    # 0x8F92EAB1 = 2408770225
    if [ "$magic" -eq 2408770225 ]; then
        log_fail "verify_no_seek_table: seekable magic 0x8F92EAB1 found — seek table present"
        return 1
    fi

    return 0
}
