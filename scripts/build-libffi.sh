#!/usr/bin/env bash
# Builds a static libffi from source for the given architecture (arm64 or x64)
# into deps/libffi-<arch>, which binding.gyp prefers over Homebrew's libffi.
#
# Homebrew's libffi is built for the host macOS version, so linking it statically
# would raise the addon's minimum macOS. Building from source lets us target
# MACOSX_DEPLOYMENT_TARGET (matching binding.gyp) without relying on old bottles.
set -euo pipefail

LIBFFI_VERSION="3.5.2"
LIBFFI_SHA256="f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc"
DEPLOYMENT_TARGET="13.3"

ARCH="${1:-}"
case "$ARCH" in
  arm64) CLANG_ARCH="arm64"; HOST="aarch64-apple-darwin" ;;
  x64) CLANG_ARCH="x86_64"; HOST="x86_64-apple-darwin" ;;
  *)
    echo "Usage: $0 <arm64|x64>" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/deps"
TARBALL="$DEPS/libffi-$LIBFFI_VERSION.tar.gz"
PREFIX="$DEPS/libffi-$ARCH"
BUILD_DIR="$DEPS/build/libffi-$LIBFFI_VERSION-$ARCH"

mkdir -p "$DEPS"

if [ ! -f "$TARBALL" ]; then
  curl -fsSL -o "$TARBALL.tmp" \
    "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz"
  mv "$TARBALL.tmp" "$TARBALL"
fi
echo "$LIBFFI_SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$BUILD_DIR" "$PREFIX"
mkdir -p "$BUILD_DIR"
tar -xzf "$TARBALL" -C "$BUILD_DIR" --strip-components=1

cd "$BUILD_DIR"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
./configure \
  --host="$HOST" \
  --prefix="$PREFIX" \
  --disable-shared \
  --enable-static \
  --with-pic \
  --disable-docs \
  --disable-multi-os-directory \
  CC="clang -arch $CLANG_ARCH" \
  CFLAGS="-O2 -mmacosx-version-min=$DEPLOYMENT_TARGET" \
  >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

echo "Built static libffi $LIBFFI_VERSION ($ARCH, macOS $DEPLOYMENT_TARGET+) in $PREFIX"
