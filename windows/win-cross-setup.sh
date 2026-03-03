#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# win-cross-setup.sh — Shared setup for Windows cross-compilation scripts.
#
# Installs llvm-mingw and downloads the zstd source tree.  All operations are
# idempotent: if the toolchain or source are already present they are reused.
#
# This file is meant to be **sourced** (not executed) by win-cross-build.sh
# and win-cross-test.sh:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/win-cross-setup.sh"
#
# Environment variables (all optional, with sensible defaults):
#
#   SRC_DIR          Path to the t2sz source tree       (default: SCRIPT_DIR/..)
#   BUILD_BASE_DIR   Where build-windows-* dirs go      (default: SRC_DIR)
#   ZSTD_VERSION     Zstd release to build against      (default: 1.5.7)
#   LLVM_MINGW_VER   llvm-mingw release tag              (default: 20250417)

# ═══════════════════════════════════════════════════════════════════════════════
# Defaults
# ═══════════════════════════════════════════════════════════════════════════════
: "${SRC_DIR:=$(cd "${SCRIPT_DIR}/.." && pwd)}"
: "${BUILD_BASE_DIR:=${SRC_DIR}}"
: "${ZSTD_VERSION:=1.5.7}"
: "${LLVM_MINGW_VER:=20250417}"

# ═══════════════════════════════════════════════════════════════════════════════
# sudo detection — root inside Docker, non-root on CI runners
# ═══════════════════════════════════════════════════════════════════════════════
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Detect host architecture
# ═══════════════════════════════════════════════════════════════════════════════
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) LLVM_HOST="aarch64" ;;
  x86_64)        LLVM_HOST="x86_64"  ;;
  *) echo "Unsupported host architecture: $HOST_ARCH"; exit 1 ;;
esac

# ═══════════════════════════════════════════════════════════════════════════════
# Install base build tools (idempotent, independent of llvm-mingw)
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v cmake &>/dev/null; then
    echo "Installing base tools (curl, cmake, make, xz-utils, file)..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq curl cmake make xz-utils file > /dev/null 2>&1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Install llvm-mingw cross-compiler (idempotent)
# ═══════════════════════════════════════════════════════════════════════════════
LLVM_MINGW_DIR="llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-${LLVM_HOST}"

if [ ! -d "/opt/${LLVM_MINGW_DIR}" ]; then
    echo "Installing llvm-mingw ${LLVM_MINGW_VER} (${LLVM_HOST})..."
    curl -fsSL \
      "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/${LLVM_MINGW_DIR}.tar.xz" \
      | $SUDO tar -xJ -C /opt
else
    echo "llvm-mingw ${LLVM_MINGW_VER} already installed."
fi
export PATH="/opt/${LLVM_MINGW_DIR}/bin:$PATH"

# ═══════════════════════════════════════════════════════════════════════════════
# Download zstd source (idempotent)
# ═══════════════════════════════════════════════════════════════════════════════
ZSTD_SRC_DIR="/tmp/zstd-${ZSTD_VERSION}"

if [ ! -d "$ZSTD_SRC_DIR" ]; then
    echo "Downloading zstd ${ZSTD_VERSION} source..."
    curl -fsSL \
      "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" \
      | tar -xz -C /tmp
else
    echo "zstd ${ZSTD_VERSION} source already present."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Exports for consuming scripts
# ═══════════════════════════════════════════════════════════════════════════════
export SRC_DIR BUILD_BASE_DIR ZSTD_VERSION LLVM_MINGW_VER
export SUDO LLVM_HOST ZSTD_SRC_DIR LLVM_MINGW_DIR
