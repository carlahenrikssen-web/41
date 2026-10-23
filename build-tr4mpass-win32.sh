#!/usr/bin/env bash
set -euo pipefail

PREFIX="$HOME/win32"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"

LIBS="libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2"

CF="$(pkg-config --cflags $LIBS)"
LF="$(pkg-config --libs $LIBS)"

make clean || true

# The chip-DB canary builds and RUNS a Windows exe; impossible on Linux. Skip it.
touch .chip-db-canary

make -j"$(nproc)" \
  CC=i686-w64-mingw32-gcc \
  CFLAGS="-O2 -std=c99 -Wall -D_GNU_SOURCE -Iinclude -Iwin32shim -include win32shim.h $CF" \
  LDFLAGS="$LF -lws2_32 -lwsock32 -lcrypt32 -lbcrypt -lshlwapi -static-libgcc"

ls -l tr4mpass.exe
file tr4mpass.exe

mkdir -p win32dll
cp -v "$PREFIX/bin/"*.dll win32dll/ || true
