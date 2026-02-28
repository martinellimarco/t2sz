#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# test_coverage.sh — Generate LLVM HTML coverage report from a coverage build
#
# Prerequisites:
#   cmake -B build_cov -DBUILD_TESTS=ON -DCOVERAGE=ON
#   cmake --build build_cov
#   cd build_cov && LLVM_PROFILE_FILE="cov_%p.profraw" ctest
#   (or: cd build_cov && ctest   — when the CMakeLists sets the env automatically)
#
# Usage:
#   bash tests/test_coverage.sh <build_dir>
#
# Output:
#   tests/coverage/html/index.html  — annotated HTML source
#   stdout                          — coverage summary table

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${1:?Usage: $0 <build_dir>}"
SRC_FILE="$SCRIPT_DIR/../src/t2sz.c"
T2SZ_BIN="$BUILD_DIR/t2sz"
PROFDATA="$BUILD_DIR/coverage.profdata"
HTML_DIR="$SCRIPT_DIR/coverage/html"

# ── Locate llvm-profdata and llvm-cov ────────────────────────────────────────
OS="$(uname -s)"

find_tool() {
    local name="$1"
    local homebrew_path="/opt/homebrew/opt/llvm/bin/$name"
    if [ "$OS" = "Darwin" ] && [ -x "$homebrew_path" ]; then
        echo "$homebrew_path"
    elif command -v "$name" >/dev/null 2>&1; then
        echo "$name"
    else
        printf "Error: '%s' not found. On macOS: brew install llvm\n" "$name" >&2
        exit 1
    fi
}

LLVM_PROFDATA="$(find_tool llvm-profdata)"
LLVM_COV="$(find_tool llvm-cov)"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[ -f "$T2SZ_BIN" ]  || { echo "Error: $T2SZ_BIN not found — did you build with -DCOVERAGE=ON?"; exit 1; }
[ -f "$SRC_FILE" ]  || { echo "Error: $SRC_FILE not found"; exit 1; }

PROFRAW_COUNT=$(find "$BUILD_DIR" -name "cov_*.profraw" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PROFRAW_COUNT" -eq 0 ]; then
    echo "Error: no cov_*.profraw files found in $BUILD_DIR"
    echo "Run ctest in the coverage build directory first."
    exit 1
fi
echo "Found $PROFRAW_COUNT profile(s) to merge."

# ── Merge profiles ────────────────────────────────────────────────────────────
echo "Merging profiles → $PROFDATA"
"$LLVM_PROFDATA" merge -sparse "$BUILD_DIR"/cov_*.profraw -o "$PROFDATA"

# ── Generate HTML report ──────────────────────────────────────────────────────
echo "Generating HTML report → $HTML_DIR"
mkdir -p "$HTML_DIR"
"$LLVM_COV" show "$T2SZ_BIN" \
    -instr-profile="$PROFDATA" \
    --format=html \
    -output-dir="$HTML_DIR" \
    "$SRC_FILE"

# ── Print summary to stdout ───────────────────────────────────────────────────
echo ""
echo "Coverage summary:"
echo "─────────────────────────────────────────────────────────────────"
"$LLVM_COV" report "$T2SZ_BIN" \
    -instr-profile="$PROFDATA" \
    "$SRC_FILE"
echo "─────────────────────────────────────────────────────────────────"
echo ""
echo "Full report: $HTML_DIR/index.html"

# ── Open in browser (macOS only, opt-out with OPEN_BROWSER=0) ─────────────────
if [ "$OS" = "Darwin" ] && [ "${OPEN_BROWSER:-1}" = "1" ]; then
    open "$HTML_DIR/index.html"
fi
