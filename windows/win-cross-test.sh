#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# win-cross-test.sh — Cross-compile t2sz for Windows and run the full CTest
# suite through Wine (Debug build with LLVM coverage).
#
# All 78 tests are driven by CTest (no manual listing here).  The trick is to
# replace the built .exe files with shell-script wrappers that call Wine:
# Linux does not care about extensions — it checks the shebang.
#
# The target architecture is auto-detected from the host.  On arm64 hosts Wine
# is non-functional, so the script falls back to build-only mode.
#
# Usage:
#   bash win-cross-test.sh
#
# Environment variables (see win-cross-setup.sh for the full list):
#   SRC_DIR            Source tree     (default: parent of script directory)
#   BUILD_BASE_DIR     Build root      (default: SRC_DIR)
#   CTEST_JOBS         CTest parallelism (default: 4)
#   CTEST_EXTRA_ARGS   Extra CTest flags (e.g. --exclude-regex raw_1gb)
#
# Docker example:
#   docker run --rm --platform linux/amd64 -v "$(pwd)":/src \
#     ubuntu:24.04 bash /src/windows/win-cross-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/win-cross-setup.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Target architecture (derived from host)
# ═══════════════════════════════════════════════════════════════════════════════
case "$HOST_ARCH" in
  aarch64|arm64) TARGET="aarch64-w64-mingw32"; ARCH="arm64" ;;
  x86_64)        TARGET="x86_64-w64-mingw32";  ARCH="amd64" ;;
esac

BUILD_DIR="${BUILD_BASE_DIR}/build-windows-${ARCH}-debug"
ZSTD_PREFIX="/tmp/zstd-${TARGET}"

echo ""
echo "====================================================="
echo "  Windows cross-build + test (${ARCH})"
echo "  Host: ${HOST_ARCH}  →  Target: ${TARGET}"
echo "====================================================="

# ═══════════════════════════════════════════════════════════════════════════════
# Install test-specific tools: Wine + zstd CLI
# ═══════════════════════════════════════════════════════════════════════════════
$SUDO apt-get install -y -qq zstd > /dev/null 2>&1
if ! command -v zstd &>/dev/null; then
    echo "ERROR: zstd CLI not available — cannot validate test outputs"
    exit 1
fi

WINE=""
if $SUDO apt-get install -y -qq wine > /dev/null 2>&1; then
    WINE="$(command -v wine64 2>/dev/null || command -v wine 2>/dev/null || true)"
fi
if [ -n "$WINE" ]; then
    # Verify Wine can actually run a Windows command — on arm64 it installs but hangs
    echo "Wine binary found: $WINE — verifying it can execute..."
    if timeout 30 env WINEDEBUG=-all "$WINE" cmd /c echo ok >/dev/null 2>&1; then
        echo "Wine: $WINE (verified working)"
    else
        echo "Wine: installed but non-functional (build-only mode)"
        WINE=""
    fi
else
    echo "Wine: not available (build-only mode)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Build zstd as a static library (idempotent — reuses build from build script)
# ═══════════════════════════════════════════════════════════════════════════════
if [ ! -f "${ZSTD_PREFIX}/lib/libzstd.a" ]; then
    echo ""
    echo "====================================================="
    echo "  Cross-compiling zstd (static, ${TARGET})"
    echo "====================================================="
    cmake -S "${ZSTD_SRC_DIR}/build/cmake" -B "/tmp/build-zstd-${TARGET}" \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER="${TARGET}-gcc" \
      -DCMAKE_RC_COMPILER="${TARGET}-windres" \
      -DCMAKE_INSTALL_PREFIX="${ZSTD_PREFIX}" \
      -DZSTD_BUILD_PROGRAMS=OFF \
      -DZSTD_BUILD_SHARED=OFF \
      -DZSTD_BUILD_STATIC=ON \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build "/tmp/build-zstd-${TARGET}" -j"$(nproc)"
    cmake --install "/tmp/build-zstd-${TARGET}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Cross-compile t2sz + gen_blob (Debug, with tests + optional coverage)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "====================================================="
echo "  Cross-compiling t2sz + tests (${TARGET})"
echo "====================================================="

# Enable LLVM source-based coverage when Wine is available for testing
COV_C_FLAGS=""
COV_LINK_FLAGS=""
if [ -n "$WINE" ]; then
    COV_C_FLAGS="-fprofile-instr-generate -fcoverage-mapping"
    COV_LINK_FLAGS="-fprofile-instr-generate"
fi

cmake -S "${SRC_DIR}" -B "$BUILD_DIR" \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_C_COMPILER="${TARGET}-gcc" \
  -DCMAKE_RC_COMPILER="${TARGET}-windres" \
  -DCMAKE_FIND_ROOT_PATH="${ZSTD_PREFIX}" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS="${COV_C_FLAGS}" \
  -DCMAKE_EXE_LINKER_FLAGS="-static ${COV_LINK_FLAGS}" \
  -DBUILD_TESTS=ON
cmake --build "$BUILD_DIR" -j"$(nproc)"

echo ""
file "$BUILD_DIR/t2sz.exe"
file "$BUILD_DIR/tests/gen_blob.exe"

if [ -z "$WINE" ]; then
    echo ""
    echo "====================================================="
    echo "  Build OK (${ARCH}) — Wine not available, skipping tests"
    echo "====================================================="
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Set up Wine wrappers for transparent CTest execution
#
# On Linux a file named "foo.exe" can be a shell script with a shebang.
# We rename the real PE to .real.exe and place a wrapper at .exe, so CTest's
# $<TARGET_FILE:t2sz> resolves to the wrapper which invokes Wine transparently.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "====================================================="
echo "  Setting up Wine wrappers for CTest"
echo "====================================================="

PROFDIR="${BUILD_DIR}/profraw"
mkdir -p "$PROFDIR"

# Initialize Wine prefix silently to avoid first-run noise
timeout 60 env WINEDEBUG=-all $WINE cmd /c exit 2>/dev/null || true

for exe in "$BUILD_DIR/t2sz.exe" "$BUILD_DIR/tests/gen_blob.exe"; do
    real="${exe%.exe}.real.exe"
    [ -f "$real" ] && continue   # already wrapped from a previous run
    mv "$exe" "$real"
    cat > "$exe" << WRAPPER
#!/bin/bash
WINEDEBUG=-all LLVM_PROFILE_FILE="${PROFDIR}/cov_%p_%m.profraw" exec $WINE "$real" "\$@"
WRAPPER
    chmod +x "$exe"
done

# Smoke test
echo ""
"$BUILD_DIR/t2sz.exe" -V || echo "(exit code: $?)"

# ═══════════════════════════════════════════════════════════════════════════════
# Run the full CTest suite (all tests — same definitions as native build)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "====================================================="
echo "  CTest — full test suite (${ARCH} via Wine)"
echo "====================================================="

cd "$BUILD_DIR"
CTEST_RC=0
ctest --output-on-failure -j"${CTEST_JOBS:-4}" ${CTEST_EXTRA_ARGS:-} || CTEST_RC=$?

# ═══════════════════════════════════════════════════════════════════════════════
# Coverage report (LLVM source-based)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "====================================================="
echo "  Coverage Report (${ARCH})"
echo "====================================================="

if ls "$PROFDIR"/cov_*.profraw 1>/dev/null 2>&1; then
    PROFDATA="${BUILD_DIR}/t2sz.profdata"
    llvm-profdata merge -sparse "$PROFDIR"/cov_*.profraw -o "$PROFDATA"

    llvm-cov report "${BUILD_DIR}/t2sz.real.exe" \
        --instr-profile="$PROFDATA" \
        --sources "${SRC_DIR}/src/"

    # Save detailed annotated-source coverage
    llvm-cov show "${BUILD_DIR}/t2sz.real.exe" \
        --instr-profile="$PROFDATA" \
        --sources "${SRC_DIR}/src/" \
        --format=text > "${BUILD_DIR}/coverage-${ARCH}.txt" 2>/dev/null || true

    echo ""
    echo "Detailed coverage saved to ${BUILD_DIR}/coverage-${ARCH}.txt"
else
    echo "No profraw files found — coverage data unavailable"
fi

echo ""
echo "====================================================="
echo "  Done (${ARCH}): CTest exit code = ${CTEST_RC}"
echo "====================================================="
exit $CTEST_RC
