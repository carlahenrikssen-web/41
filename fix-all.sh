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

echo "===== 1. complete openssl headers ====="
TREE="$(ls -d "$SRC"/openssl-3.0.* 2>/dev/null | head -1)"
[ -n "${TREE:-}" ] || { echo "NO_OPENSSL_TREE"; exit 1; }
( cd "$TREE" && make install_dev ) >/dev/null 2>&1 || true
mkdir -p "$PREFIX/include/openssl"
find "$TREE" -name '*.h' -path '*include/openssl*' -exec cp -f {} "$PREFIX/include/openssl/" \; 2>/dev/null || true
for h in opensslv.h configuration.h opensslconf.h err.h ssl.h evp.h hmac.h sha.h; do
  [ -f "$PREFIX/include/openssl/$h" ] && echo "HDR OK      $h" || echo "HDR MISSING $h"
done
[ -f "$PREFIX/include/openssl/configuration.h" ] || { echo "OPENSSL_HEADERS INCOMPLETE"; exit 1; }
echo "OPENSSL_HEADERS OK"

echo "===== 2. libimobiledevice 1.3.0 only (master needs ifaddrs patch) ====="
V=1.3.0
cd "$SRC" || exit 1
if [ ! -s "libimobiledevice-$V.tar.bz2" ]; then
  wget -q -O "libimobiledevice-$V.tar.bz2" \
    "https://github.com/libimobiledevice/libimobiledevice/releases/download/$V/libimobiledevice-$V.tar.bz2" \
  || { echo "IMD_DOWNLOAD_FAILED"; exit 1; }
fi
rm -rf "libimobiledevice-$V"
tar xjf "libimobiledevice-$V.tar.bz2" || { echo "IMD_TAR_FAILED"; exit 1; }
cd "libimobiledevice-$V" || exit 1
./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" \
  --enable-static --disable-shared --without-cython \
  LDFLAGS="-L$PREFIX/lib $WINLIBS" > cfg.out 2>&1 \
  || { echo "IMD_CONFIGURE_FAILED"; tail -20 cfg.out; exit 1; }
make -j"$(nproc)" > mk.out 2>&1 || { echo "IMD_MAKE_FAILED"; grep -E 'error:|undefined reference' mk.out | head -10; exit 1; }
make -C src install >/dev/null 2>&1
make -C include install >/dev/null 2>&1
pkg-config --exists libimobiledevice-1.0 \
  && echo "IMD OK $(pkg-config --modversion libimobiledevice-1.0)" \
  || { echo "IMD_PKG_MISSING"; exit 1; }

echo "===== 3. netinet / arpa shims for winsock ====="
mkdir -p win32shim/netinet win32shim/arpa win32shim/sys
printf '#ifndef TP_W_NETINET_IN_H\n#define TP_W_NETINET_IN_H\n#include <winsock2.h>\n#include <ws2tcpip.h>\n#endif\n' > win32shim/netinet/in.h
printf '#ifndef TP_W_ARPA_INET_H\n#define TP_W_ARPA_INET_H\n#include <winsock2.h>\n#include <ws2tcpip.h>\n#endif\n' > win32shim/arpa/inet.h

echo "===== 4. per-package pkg-config (a missing one must not blank the rest) ====="
CF=""; LF=""
for p in libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2 libtatsu-1.0; do
  if pkg-config --exists "$p"; then
    CF="$CF $(pkg-config --cflags "$p")"
    LF="$LF $(pkg-config --static --libs "$p")"
  else
    echo "WARN missing $p"
  fi
done
echo "CFLAGS_EXTRA:$CF"

echo "===== 5. drop the canary prerequisite (it runs a Windows exe) ====="
sed -i 's/^$(TARGET): \.chip-db-canary $(OBJS)/$(TARGET): $(OBJS)/' Makefile
grep -n '^\$(TARGET):' Makefile

echo "===== 6. compile ====="
make clean >/dev/null 2>&1 || true
make -j"$(nproc)" \
  CC=i686-w64-mingw32-gcc \
  CFLAGS="-O2 -std=c99 -D_GNU_SOURCE -Iinclude -Iwin32shim -include win32shim.h $CF" \
  LDFLAGS="$LF $WINLIBS -lwsock32 -lshlwapi -static-libgcc" \
  > build.out 2>&1 || true
grep -E 'error:|undefined reference|No such file' build.out | head -20 || true
ls -l tr4mpass.exe 2>/dev/null && file tr4mpass.exe || echo "NO_EXE"
