#!/usr/bin/env bash
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
