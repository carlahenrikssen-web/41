#!/usr/bin/env bash
set -uo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
JOBS="$(nproc 2>/dev/null || echo 4)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_ALLOW_CROSS=1
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
WINLIBS="-lws2_32 -lcrypt32 -lsecur32 -lbcrypt -ladvapi32 -lgdi32 -luser32"

step() { echo; echo "===== $* ====="; }

# ============================================================
# 1. openssl - rebuild cleanly, install COMPLETE generated headers
# ============================================================
step "1 openssl"
V=3.0.15
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
cd "$SRC" || exit 1

TB="openssl-$V.tar.gz"
if [ ! -s "$TB" ]; then
  curl -fsSL -o "$TB" "https://github.com/openssl/openssl/releases/download/openssl-$V/$TB" \
    || wget -q -O "$TB" "https://www.openssl.org/source/old/3.0/$TB" \
    || wget -q -O "$TB" "https://www.openssl.org/source/$TB" \
    || { echo "OPENSSL_DOWNLOAD_FAILED"; exit 1; }
fi
rm -rf "openssl-$V"
tar xzf "$TB" || { echo "OPENSSL_TAR_FAILED"; exit 1; }
cd "openssl-$V" || exit 1

./Configure mingw no-shared no-tests no-docs \
  --prefix="$PREFIX" --cross-compile-prefix="$HOST-" > cfg.out 2>&1 \
  || { echo "OPENSSL_CONFIGURE_FAILED"; tail -15 cfg.out; exit 1; }

make -j"$JOBS" build_libs > mk.out 2>&1 \
  || { echo "OPENSSL_MAKE_FAILED"; tail -25 mk.out; exit 1; }

# Install generated headers: opensslv.h / configuration.h / opensslconf.h
# only exist in the build tree after Configure runs.
mkdir -p "$PREFIX/include/openssl"
cp -a include/openssl/. "$PREFIX/include/openssl/" 2>/dev/null || true
cp -f libcrypto.a libssl.a "$PREFIX/lib/" 2>/dev/null || true

for h in opensslv.h configuration.h opensslconf.h err.h ssl.h crypto.h evp.h; do
  if [ -f "$PREFIX/include/openssl/$h" ]; then
    echo "HDR OK      $h"
  else
    echo "HDR MISSING $h"
    [ "$h" = "configuration.h" ] && CPFAIL=1
  fi
done
if [ "${CPFAIL:-0}" = "1" ]; then
  echo "OPENSSL_HEADERS INCOMPLETE"
  echo "--- what the tree actually has ---"
  ls include/openssl/ 2>/dev/null | head -20
  exit 1
fi
echo "OPENSSL_HEADERS OK"

printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: OpenSSL\nDescription: OpenSSL\nVersion: %s\nLibs: -L${libdir} -lssl -lcrypto\nLibs.private: %s\nCflags: -I${includedir}\n' \
  "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/openssl.pc"
printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libcrypto\nDescription: OpenSSL libcrypto\nVersion: %s\nLibs: -L${libdir} -lcrypto\nLibs.private: %s\nCflags: -I${includedir}\n' \
  "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/libcrypto.pc"
printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libssl\nDescription: OpenSSL libssl\nVersion: %s\nLibs: -L${libdir} -lssl\nLibs.private: -lcrypto %s\nCflags: -I${includedir}\n' \
  "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/libssl.pc"

if pkg-config --exists openssl; then
  echo "OPENSSL_PC OK $(pkg-config --modversion openssl)"
else
  echo "OPENSSL_PC MISSING"
  exit 1
fi

# ============================================================
# 2. libimobiledevice 1.3.0 (master needs an ifaddrs patch)
# ============================================================
step "2 libimobiledevice 1.3.0"
IMV=1.3.0
cd "$SRC" || exit 1

if [ ! -d "$SRC/libimobiledevice-$IMV" ]; then
  if [ ! -s "libimobiledevice-$IMV.tar.bz2" ]; then
    curl -fsSL -o "libimobiledevice-$IMV.tar.bz2" \
      "https://github.com/libimobiledevice/libimobiledevice/releases/download/$IMV/libimobiledevice-$IMV.tar.bz2" \
      || echo "IMD_TARBALL_UNAVAILABLE"
  fi
  if [ -s "libimobiledevice-$IMV.tar.bz2" ]; then
    tar xjf "libimobiledevice-$IMV.tar.bz2" || { echo "IMD_TAR_FAILED"; exit 1; }
  else
    echo "IMD_FALLBACK git tag $IMV"
    rm -rf "libimobiledevice-$IMV"
    git clone --depth 1 --branch "$IMV" \
      https://github.com/libimobiledevice/libimobiledevice.git \
      "libimobiledevice-$IMV" || { echo "IMD_CLONE_FAILED"; exit 1; }
  fi
fi

cd "$SRC/libimobiledevice-$IMV" || exit 1
if [ ! -x ./configure ]; then
  ( NOCONFIGURE=1 ./autogen.sh ) > ag.out 2>&1 \
    || { echo "IMD_AUTOGEN_FAILED"; tail -20 ag.out; exit 1; }
fi

if ./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" \
     --enable-static --disable-shared --without-cython \
     LDFLAGS="-L$PREFIX/lib $WINLIBS" > cfg.out 2>&1; then
  echo "IMD_CONFIGURE OK"
  grep -nE 'checking for openssl' cfg.out || true
else
  echo "IMD_CONFIGURE_FAILED"
  grep -nE 'error|not found|openssl' cfg.out | tail -15
  exit 1
fi

if make -j"$JOBS" > mk.out 2>&1; then
  echo "IMD_MAKE OK"
else
  echo "IMD_MAKE_FAILED"
  grep -nE 'error:|undefined reference|No such file' mk.out | head -15
  exit 1
fi

make -C src install > /dev/null 2>&1 || true
make -C include install > /dev/null 2>&1 || true
if pkg-config --exists libimobiledevice-1.0; then
  echo "IMD OK $(pkg-config --modversion libimobiledevice-1.0)"
else
  echo "IMD_PKG_MISSING"
  exit 1
fi

# ============================================================
# 3. winsock shims
# ============================================================
step "3 shims"
mkdir -p win32shim/netinet win32shim/arpa win32shim/sys
printf '#ifndef TP_W_NETINET_IN_H\n#define TP_W_NETINET_IN_H\n#include <winsock2.h>\n#include <ws2tcpip.h>\n#endif\n' > win32shim/netinet/in.h
printf '#ifndef TP_W_ARPA_INET_H\n#define TP_W_ARPA_INET_H\n#include <winsock2.h>\n#include <ws2tcpip.h>\n#endif\n' > win32shim/arpa/inet.h
printf '#ifndef TP_W_SYS_SOCKET_H\n#define TP_W_SYS_SOCKET_H\n#include <winsock2.h>\n#include <ws2tcpip.h>\n#endif\n' > win32shim/sys/socket.h
ls -l win32shim/netinet/in.h win32shim/arpa/inet.h win32shim/sys/socket.h

# ============================================================
# 4. per-package pkg-config flags
# ============================================================
step "4 pkg-config"
CF=""
LF=""
for p in libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2 libtatsu-1.0; do
  if pkg-config --exists "$p"; then
    CF="$CF $(pkg-config --cflags "$p")"
    LF="$LF $(pkg-config --static --libs "$p")"
    echo "found   $p $(pkg-config --modversion "$p")"
  else
    echo "WARN    missing $p"
  fi
done
echo "CF=[$CF]"
echo "LF=[$LF]"

# ============================================================
# 5. drop the phony canary prerequisite
# ============================================================
step "5 makefile canary"
sed -i 's/^$(TARGET): \.chip-db-canary/$(TARGET):/' Makefile
grep -n '^\$(TARGET):' Makefile

# ============================================================
# 6. compile
# ============================================================
step "6 compile"
make clean > /dev/null 2>&1 || true
make -j"$JOBS" \
  CC=i686-w64-mingw32-gcc \
  CFLAGS="-O2 -std=c99 -D_GNU_SOURCE -Iinclude -Iwin32shim -include win32shim.h $CF" \
  LDFLAGS="$LF $WINLIBS -lwsock32 -lshlwapi -static-libgcc" \
  > build.out 2>&1
echo "make exit: $?"
grep -nE 'error:|undefined reference|No such file' build.out | head -25 || true

if [ -f tr4mpass.exe ]; then
  ls -l tr4mpass.exe
  file tr4mpass.exe
  mkdir -p win32dll
  cp -f "$PREFIX/bin/"*.dll win32dll/ 2>/dev/null || true
else
  echo "NO_EXE"
  tail -15 build.out
fi
