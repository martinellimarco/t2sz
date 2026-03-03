#!/usr/bin/env bash
# win-cross-build.sh — Cross-compile t2sz for Windows (Release, static).
#
# Produces stripped executables in build-windows-{arch}-release/.
#
# Usage:
#   bash win-cross-build.sh [amd64|arm64|both]   (default: both)
#
# Environment variables (see win-cross-setup.sh for the full list):
#   SRC_DIR          Source tree  (default: parent of script directory)
#   BUILD_BASE_DIR   Build root   (default: SRC_DIR)
#
# Docker example:
#   docker run --rm -v "$(pwd)":/src \
#     ubuntu:24.04 bash /src/windows/win-cross-build.sh both

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/win-cross-setup.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Build one architecture
# ═══════════════════════════════════════════════════════════════════════════════
build_one() {
    local MINGW_TARGET="$1" ARCH="$2"
    local BUILD_DIR="${BUILD_BASE_DIR}/build-windows-${ARCH}-release"
    local ZSTD_PREFIX="/tmp/zstd-${MINGW_TARGET}"

    echo ""
    echo "====================================================="
    echo "  Building for ${MINGW_TARGET}  (${ARCH})"
    echo "====================================================="

    # --- Build zstd as a static library (idempotent) ---
    if [ ! -f "${ZSTD_PREFIX}/lib/libzstd.a" ]; then
        cmake -S "${ZSTD_SRC_DIR}/build/cmake" -B "/tmp/build-zstd-${MINGW_TARGET}" \
          -DCMAKE_SYSTEM_NAME=Windows \
          -DCMAKE_C_COMPILER="${MINGW_TARGET}-gcc" \
          -DCMAKE_RC_COMPILER="${MINGW_TARGET}-windres" \
          -DCMAKE_INSTALL_PREFIX="${ZSTD_PREFIX}" \
          -DZSTD_BUILD_PROGRAMS=OFF \
          -DZSTD_BUILD_SHARED=OFF \
          -DZSTD_BUILD_STATIC=ON \
          -DCMAKE_BUILD_TYPE=Release
        cmake --build "/tmp/build-zstd-${MINGW_TARGET}" -j"$(nproc)"
        cmake --install "/tmp/build-zstd-${MINGW_TARGET}"
    fi

    # --- Build t2sz ---
    cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER="${MINGW_TARGET}-gcc" \
      -DCMAKE_RC_COMPILER="${MINGW_TARGET}-windres" \
      -DCMAKE_FIND_ROOT_PATH="${ZSTD_PREFIX}" \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXE_LINKER_FLAGS="-static"
    cmake --build "${BUILD_DIR}" -j"$(nproc)"

    # --- Strip ---
    "${MINGW_TARGET}-strip" "${BUILD_DIR}/t2sz.exe"

    echo ""
    file "${BUILD_DIR}/t2sz.exe"
    ls -lh "${BUILD_DIR}/t2sz.exe"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main — select architectures
# ═══════════════════════════════════════════════════════════════════════════════
ARCHES="${1:-both}"

case "$ARCHES" in
  amd64) build_one x86_64-w64-mingw32  amd64 ;;
  arm64) build_one aarch64-w64-mingw32 arm64 ;;
  both)
    build_one x86_64-w64-mingw32  amd64
    build_one aarch64-w64-mingw32 arm64
    ;;
  *) echo "Usage: $0 [amd64|arm64|both]"; exit 1 ;;
esac

echo ""
echo "====================================================="
echo "  Done!  Release executables:"
echo "====================================================="
ls -lh "${BUILD_BASE_DIR}"/build-windows-*-release/t2sz.exe 2>/dev/null || true
