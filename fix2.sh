#!/usr/bin/env bash
set -euo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
JOBS=$(nproc 2>/dev/null || echo 2)

mkdir -p "$PREFIX"/{bin,lib,include,lib/pkgconfig} "$SRC"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_ALLOW_CROSS=1
export PATH="$PREFIX/bin:$PATH"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
WINLIBS="-lws2_32 -liphlpapi -lcrypt32 -lsecur32 -lbcrypt -ladvapi32 -lgdi32 -luser32"

step() { echo; echo "===== $* ====="; }

# ---------------------------------------------------------------
# 0. early winsock / ifaddrs shims
# ---------------------------------------------------------------
step "0 early shims"
SHIM="$SRC/win32shim"
mkdir -p "$SHIM"/{netinet,arpa,sys}

cat > "$SHIM/netinet/in.h" << 'H'
#ifndef TP_W_NETINET_IN_H
#define TP_W_NETINET_IN_H
#include <winsock2.h>
#include <ws2tcpip.h>
#endif
H

cat > "$SHIM/arpa/inet.h" << 'H'
#ifndef TP_W_ARPA_INET_H
#define TP_W_ARPA_INET_H
#include <winsock2.h>
#include <ws2tcpip.h>
#endif
H

cat > "$SHIM/sys/socket.h" << 'H'
#ifndef TP_W_SYS_SOCKET_H
#define TP_W_SYS_SOCKET_H
#include <winsock2.h>
#include <ws2tcpip.h>
#endif
H

cat > "$SHIM/ifaddrs.h" << 'H'
#ifndef TP_W_IFADDRS_H
#define TP_W_IFADDRS_H
#include <winsock2.h>
#include <ws2tcpip.h>
struct ifaddrs {
    struct ifaddrs *ifa_next;
    char *ifa_name;
    unsigned int ifa_flags;
    struct sockaddr *ifa_addr;
    struct sockaddr *ifa_netmask;
    struct sockaddr *ifa_dstaddr;
    void *ifa_data;
};
#ifndef IFF_UP
#define IFF_UP 0x1
#endif
#ifndef IFF_RUNNING
#define IFF_RUNNING 0x40
#endif
static inline int getifaddrs(struct ifaddrs **ifap) { *ifap = NULL; return -1; }
static inline void freeifaddrs(struct ifaddrs *ifa) { (void)ifa; }
#endif
H

: > "$SHIM/win32shim.h"

echo "SHIM_DIR=$SHIM"
ls -1 "$SHIM" "$SHIM/netinet" "$SHIM/arpa" "$SHIM/sys"

# ---------------------------------------------------------------
# 1. OpenSSL 3.0.15
# ---------------------------------------------------------------
step "1 openssl"
OV=3.0.15
cd "$SRC"
if [ ! -d "openssl-$OV" ]; then
  curl -fsSL -o "openssl-$OV.tar.gz" \
    "https://www.openssl.org/source/openssl-$OV.tar.gz" || \
  curl -fsSL -o "openssl-$OV.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OV/openssl-$OV.tar.gz"
  tar xzf "openssl-$OV.tar.gz"
fi
cd "openssl-$OV"
make distclean >/dev/null 2>&1 || true

./Configure mingw --prefix="\( PREFIX" --cross-compile-prefix=" \){HOST}-" \
  no-shared no-tests no-async no-dso \
  -I"$SHIM" > cfg.out 2>&1 || {
  echo "OPENSSL_CONFIGURE_FAILED"
  tail -40 cfg.out
  exit 1
}

make -j"$JOBS" > mk.out 2>&1 || {
  echo "OPENSSL_MAKE_FAILED"
  grep -nE 'error:|fatal' mk.out | head -20
  exit 1
}
make install_sw > /dev/null

for h in opensslv.h configuration.h opensslconf.h err.h ssl.h crypto.h evp.h; do
  if [ -f "$PREFIX/include/openssl/$h" ]; then
    echo "HDR OK      $h"
  else
    echo "HDR MISSING $h"
    exit 1
  fi
done
echo "OPENSSL_HEADERS OK"

V=$(grep OPENSSL_VERSION_STR "$PREFIX/include/openssl/opensslv.h" | head -1 | sed 's/.*"\(.*\)".*/\1/')
printf 'prefix=%s
libdir=${prefix}/lib
includedir=${prefix}/include

Name: OpenSSL
Description: OpenSSL
Version: %s
Libs: -L${libdir} -lssl -lcrypto
Libs.private: %s
Cflags: -I${includedir}
' "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/openssl.pc"

printf 'prefix=%s
libdir=${prefix}/lib
includedir=${prefix}/include

Name: libcrypto
Description: OpenSSL libcrypto
Version: %s
Libs: -L${libdir} -lcrypto
Libs.private: %s
Cflags: -I${includedir}
' "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/libcrypto.pc"

printf 'prefix=%s
libdir=${prefix}/lib
includedir=${prefix}/include

Name: libssl
Description: OpenSSL libssl
Version: %s
Libs: -L${libdir} -lssl
Libs.private: -lcrypto %s
Cflags: -I${includedir}
' "$PREFIX" "$V" "$WINLIBS" > "$PREFIX/lib/pkgconfig/libssl.pc"

echo "OPENSSL_PC OK $V"

# ---------------------------------------------------------------
# 2. libimobiledevice 1.3.0
# ---------------------------------------------------------------
step "2 libimobiledevice 1.3.0"
IMV=1.3.0
cd "$SRC"

if [ ! -d "libimobiledevice-$IMV" ]; then
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

cd "libimobiledevice-$IMV"
make distclean >/dev/null 2>&1 || true

if [ ! -x ./configure ]; then
  ( NOCONFIGURE=1 ./autogen.sh ) > ag.out 2>&1 || {
    echo "IMD_AUTOGEN_FAILED"
    tail -30 ag.out
    exit 1
  }
fi

IMD_CPPFLAGS="-I$PREFIX/include -I$SHIM"
IMD_CFLAGS="-O2 -I$PREFIX/include -I$SHIM"
IMD_LDFLAGS="-L$PREFIX/lib $WINLIBS"

if ./configure \
     --host="\( HOST" --build=" \)(gcc -dumpmachine)" \
     --prefix="$PREFIX" \
     --enable-static --disable-shared --without-cython \
     CC="${HOST}-gcc" \
     CPPFLAGS="$IMD_CPPFLAGS" \
     CFLAGS="$IMD_CFLAGS" \
     LDFLAGS="$IMD_LDFLAGS" > cfg.out 2>&1; then
  echo "IMD_CONFIGURE OK"
  grep -E 'checking for (openssl|libusbmuxd|libplist|libimobiledevice-glue|libtatsu)' cfg.out | tail -8 || true
else
  echo "IMD_CONFIGURE_FAILED"
  grep -nE 'error|not found|Package requirements|openssl' cfg.out | tail -30
  echo "--- config.log tail ---"
  tail -40 config.log 2>/dev/null || true
  exit 1
fi

if make -j"$JOBS" > mk.out 2>&1; then
  echo "IMD_MAKE OK"
else
  echo "IMD_MAKE_FAILED"
  grep -nE 'error:|undefined reference|No such file|ifaddrs|IFF_|PLIST_FORMAT' mk.out | head -40
  exit 1
fi

make install > inst.out 2>&1 || {
  make -C src install >> inst.out 2>&1 || true
  make -C include install >> inst.out 2>&1 || true
  echo "IMD_INSTALL_PARTIAL"
}

if [ ! -f "$PREFIX/lib/pkgconfig/libimobiledevice-1.0.pc" ]; then
  PC=$(find . -name 'libimobiledevice-1.0.pc' 2>/dev/null | head -1)
  if [ -n "$PC" ]; then
    mkdir -p "$PREFIX/lib/pkgconfig"
    cp -f "$PC" "$PREFIX/lib/pkgconfig/"
    echo "IMD_PC_COPIED $PC"
  fi
fi

ls -1 "$PREFIX/include/libimobiledevice/libimobiledevice.h" 2>/dev/null || echo "IMD_HEADER_MISSING"

if pkg-config --exists libimobiledevice-1.0; then
  echo "IMD OK $(pkg-config --modversion libimobiledevice-1.0)"
else
  echo "IMD_PKG_MISSING"
  exit 1
fi

# ---------------------------------------------------------------
# 3. shims (already done)
# ---------------------------------------------------------------
step "3 shims"
ls -l "$SHIM"/netinet/in.h "$SHIM"/arpa/inet.h "$SHIM"/sys/socket.h "$SHIM"/ifaddrs.h

# ---------------------------------------------------------------
# 4. collect pkg-config flags
# ---------------------------------------------------------------
step "4 pkg-config"
CF=""
LF=""
for p in libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2 libtatsu-1.0; do
  if pkg-config --exists "$p"; then
    echo "found   $p $(pkg-config --modversion "$p")"
    CF="$CF $(pkg-config --cflags "$p")"
    LF="$LF $(pkg-config --libs "$p")"
  else
    echo "WARN    missing $p"
  fi
done
CF="-I$SHIM $CF"
LF="$LF $WINLIBS"
echo "CF=[$CF]"
echo "LF=[$LF]"

# ---------------------------------------------------------------
# 5. makefile canary
# ---------------------------------------------------------------
step "5 makefile canary"

# ---------------------------------------------------------------
# 6. final compile stage
# ---------------------------------------------------------------
step "6 compile"
cd "$SRC" || exit 1
echo "REACHED_COMPILE_STAGE"
if [ -f tr4mpass.exe ]; then
  file tr4mpass.exe
  echo "PE32 OK"
else
  echo "NO_EXE (adjust step 6 for your real sources)"
fi
