#!/usr/bin/env bash
set -uo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_ALLOW_CROSS=1
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
WINLIBS="-lws2_32 -lcrypt32 -lsecur32 -lbcrypt -ladvapi32 -lgdi32 -luser32"

echo "=== deps visible to pkg-config ==="
for p in libusbmuxd-2.0 libplist-2.0 libimobiledevice-glue-1.0 libtatsu-1.0 libcurl; do
  if pkg-config --exists "$p"; then echo "found    $p $(pkg-config --modversion "$p")"
  else echo "MISSING  $p"; fi
done

# Build a libimobiledevice tree and install ONLY the library + headers.
# The bundled tools (ideviceinfo.exe etc.) are what usually fail to link
# on MinGW; we do not need them to link tr4mpass.
try_imd() {
  local dir="$1"
  cd "$SRC/$dir" || return 1
  [ -x ./configure ] || ( NOCONFIGURE=1 ./autogen.sh ) || return 1
  ./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" \
    --enable-static --disable-shared --without-cython \
    LDFLAGS="-L$PREFIX/lib $WINLIBS" || return 1
  make -j"$(nproc)" || true
  make -C src install || return 1
  make -C include install || true
  pkg-config --exists libimobiledevice-1.0
}

echo
echo "=== attempt 1: master tree (lib + headers only) ==="
if try_imd libimobiledevice; then
  echo "IMD_RESULT OK_master $(pkg-config --modversion libimobiledevice-1.0)"
  exit 0
fi
echo "IMD attempt 1 failed - dumping last 20 lines"
tail -20 "$SRC/libimobiledevice/config.log" 2>/dev/null || true

echo
echo "=== attempt 2: 1.3.0 release tarball (no libtatsu dependency) ==="
V=1.3.0
cd "$SRC" || exit 1
if [ ! -s "libimobiledevice-$V.tar.bz2" ] && [ ! -s "libimobiledevice-$V.tar.gz" ]; then
  wget -q -O "libimobiledevice-$V.tar.bz2" \
    "https://github.com/libimobiledevice/libimobiledevice/releases/download/$V/libimobiledevice-$V.tar.bz2" \
  || wget -q -O "libimobiledevice-$V.tar.gz" \
    "https://github.com/libimobiledevice/libimobiledevice/releases/download/$V/libimobiledevice-$V.tar.gz" \
  || echo "IMD_DOWNLOAD_FAILED"
fi
rm -rf "libimobiledevice-$V"
if [ -s "libimobiledevice-$V.tar.bz2" ]; then
  tar xjf "libimobiledevice-$V.tar.bz2"
elif [ -s "libimobiledevice-$V.tar.gz" ]; then
  tar xzf "libimobiledevice-$V.tar.gz"
fi

if [ -d "libimobiledevice-$V" ] && try_imd "libimobiledevice-$V"; then
  echo "IMD_RESULT OK_130 $(pkg-config --modversion libimobiledevice-1.0)"
  exit 0
fi

echo "IMD_RESULT FAILED_BOTH"
echo "----- master config.log tail -----"
tail -25 "$SRC/libimobiledevice/config.log" 2>/dev/null || true
echo "----- 1.3.0 config.log tail -----"
tail -25 "$SRC/libimobiledevice-$V/config.log" 2>/dev/null || true
exit 1
