#!/usr/bin/env bash
set -uo pipefail

PREFIX="$HOME/win32"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"

# libtatsu added: static libimobiledevice pulls its symbols (run #8 finding)
LIBS="libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2 libtatsu-1.0"

CF="$(pkg-config --cflags $LIBS)"
# --static is required: several libs are static archives now, and their
# private Winsock/crypto deps live in Libs.private, which plain --libs drops.
LF="$(pkg-config --static --libs $LIBS)"

make clean || true
touch .chip-db-canary   # canary would build+run a Windows exe; impossible on Linux

make -j"$(nproc)" \
  CC=i686-w64-mingw32-gcc \
  CFLAGS="-O2 -std=c99 -Wall -D_GNU_SOURCE -Iinclude -Iwin32shim -include win32shim.h $CF" \
  LDFLAGS="$LF -lws2_32 -lwsock32 -liphlpapi -lcrypt32 -lbcrypt -lsecur32 -lshlwapi -static-libgcc"

ls -l tr4mpass.exe
file tr4mpass.exe
