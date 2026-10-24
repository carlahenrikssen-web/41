#!/usr/bin/env bash
set -euo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
JOBS=$(nproc 2>/dev/null || echo 2)

mkdir -p "$PREFIX/bin" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$SRC"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_ALLOW_CROSS=1
export PATH="$PREFIX/bin:$PATH"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
WINLIBS="-lws2_32 -liphlpapi -lcrypt32 -lsecur32 -lbcrypt -ladvapi32 -lgdi32 -luser32"

step() { echo; echo "===== $* ====="; }

# ---------- 0. winsock / ifaddrs shims ----------
step "0 shims"
SHIM="$SRC/win32shim"
mkdir -p "$SHIM/netinet" "$SHIM/arpa" "$SHIM/sys"

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

# ---------- 1. OpenSSL 3.0.15 ----------
step "1 openssl"
OV=3.0.15
cd "$SRC"
if [ ! -d "openssl-$OV" ]; then
  rm -rf "openssl-$OV"
  curl -fsSL -o "openssl-$OV.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$OV/openssl-$OV.tar.gz"
  tar xzf "openssl-$OV.tar.gz"
fi
cd "openssl-$OV"
make distclean > /dev/null 2>&1 || true

./Configure mingw --prefix="$PREFIX" --cross-compile-prefix="$HOST-" \
  no-shared no-tests no-async no-dso -I"$SHIM" > cfg.out 2>&1 || {
  echo "OPENSSL_CONFIGURE_FAILED"
  tail -50 cfg.out
  exit 1
}

make -j"$JOBS" build_libs > mk.out 2>&1 || {
  echo "OPENSSL_MAKE_FAILED"
  grep -nE 'error:|fatal' mk.out | head -20
  exit 1
}
make install_sw > /dev/null

for h in opensslv.h configuration.h opensslconf.h err.h ssl.h crypto.h evp.h; do
  [ -f "$PREFIX/include/openssl/$h" ] && echo "HDR OK      $h" || { echo "HDR MISSING $h"; exit 1; }
done
echo "OPENSSL_HEADERS OK"

V=$(grep -m1 OPENSSL_VERSION_STR "$PREFIX/include/openssl/opensslv.h" | sed 's/.*"\(.*\)".*/\1/')
for name in openssl libcrypto libssl; do
  libsl="-lssl -lcrypto"
  [ "$name" = "libcrypto" ] && libsl="-lcrypto"
  [ "$name" = "libssl" ] && libsl="-lssl -lcrypto"
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: %s\nDescription: %s\nVersion: %s\nLibs: -L${libdir} %s\nLibs.private: %s\nCflags: -I${includedir}\n' \
    "$PREFIX" "$name" "$name" "$V" "$libsl" "$WINLIBS" > "$PREFIX/lib/pkgconfig/$name.pc"
done
echo "OPENSSL_PC OK $V"
pkg-config --exists openssl && echo "pkg-config openssl: OK" || { echo "pkg-config openssl: FAIL"; exit 1; }

# ---------- 2. libimobiledevice 1.4.0 ----------
step "2 libimobiledevice 1.4.0"
IMV=1.4.0
cd "$SRC"

if [ ! -d "libimobiledevice-$IMV" ]; then
  if [ -s "$HOME/41/vendor/libimobiledevice-$IMV.zip" ]; then
    echo "Using vendor zip"
    cp "$HOME/41/vendor/libimobiledevice-$IMV.zip" .
  elif ! curl -fsSL -o "libimobiledevice-$IMV.zip" "https://github.com/libimobiledevice/libimobiledevice/archive/refs/tags/$IMV.zip"; then
    echo "IMD_ZIP_DOWNLOAD_FAILED"
    exit 1
  fi
  command -v unzip > /dev/null 2>&1 || pkg install -y unzip
  unzip -q -o "libimobiledevice-$IMV.zip"
fi

cd "libimobiledevice-$IMV"

# zip has no git metadata: pin version so git-version-gen does not fail
if [ ! -d .git ] && [ ! -f .tarball-version ]; then
  echo "$IMV" > .tarball-version
fi

make distclean > /dev/null 2>&1 || true

if [ ! -x ./configure ]; then
  ( NOCONFIGURE=1 ./autogen.sh ) > ag.out 2>&1 || {
    echo "IMD_AUTOGEN_FAILED"
    tail -40 ag.out
    exit 1
  }
fi

# 1.4.0 hard-appends -Werror; cross-compile warnings would abort the build
sed -i 's/ -Werror//g' configure

openssl_CFLAGS="-I$PREFIX/include"
openssl_LIBS="-L$PREFIX/lib -lssl -lcrypto $WINLIBS"
export openssl_CFLAGS openssl_LIBS

IMD_CPPFLAGS="-I$PREFIX/include -I$SHIM -DLIBUSBMUXD_STATIC -DLIMD_GLUE_STATIC -DLIBPLIST_STATIC -DIRECV_STATIC"
IMD_CFLAGS="-O2 -I$PREFIX/include -I$SHIM -DLIBUSBMUXD_STATIC -DLIMD_GLUE_STATIC -DLIBPLIST_STATIC -DIRECV_STATIC"
IMD_LDFLAGS="-L$PREFIX/lib $WINLIBS"

if ./configure \
     --host="$HOST" \
     --build="$(gcc -dumpmachine)" \
     --prefix="$PREFIX" \
     --enable-static --disable-shared --without-cython \
     --with-openssl \
     CC="${HOST}-gcc" \
     CPPFLAGS="$IMD_CPPFLAGS" \
     CFLAGS="$IMD_CFLAGS" \
     LDFLAGS="$IMD_LDFLAGS" > cfg.out 2>&1; then
  echo "IMD_CONFIGURE OK"
  grep -E 'checking for (openssl|libusbmuxd|libplist|libimobiledevice-glue|libtatsu)' cfg.out | tail -8 || true
else
  echo "IMD_CONFIGURE_FAILED"
  grep -nE 'error|not found|Package requirements|openssl' cfg.out | tail -40
  echo "--- config.log tail ---"
  tail -50 config.log 2>/dev/null || true
  exit 1
fi

if make -j"$JOBS" > mk.out 2>&1; then
  echo "IMD_MAKE OK"
else
  echo "IMD_MAKE_FAILED"
  grep -nE 'error:|undefined reference|No such file' mk.out | head -30
  exit 1
fi

make install > inst.out 2>&1 || {
  make -C src install > inst.out 2>&1 || true
  make -C include install >> inst.out 2>&1 || true
  echo "IMD_INSTALL_PARTIAL"
}

[ -f "$PREFIX/lib/pkgconfig/libimobiledevice-1.0.pc" ] || {
  PC=$(find . -name 'libimobiledevice-1.0.pc' | head -1)
  [ -n "$PC" ] && { mkdir -p "$PREFIX/lib/pkgconfig"; cp -f "$PC" "$PREFIX/lib/pkgconfig/"; echo "IMD_PC_COPIED $PC"; }
}
[ -f "$PREFIX/include/libimobiledevice/libimobiledevice.h" ] && echo "IMD_HEADER OK" || echo "IMD_HEADER_MISSING"
pkg-config --exists libimobiledevice-1.0 && echo "IMD OK $(pkg-config --modversion libimobiledevice-1.0)" || { echo "IMD_PKG_MISSING"; exit 1; }

# ---------- 3. collect pkg-config flags ----------
step "3 pkg-config"
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
CF="-I$SHIM -DLIBUSBMUXD_STATIC -DLIMD_GLUE_STATIC -DLIBPLIST_STATIC -DIRECV_STATIC $CF"
LF="$LF $WINLIBS"
echo "CF=[$CF]"
echo "LF=[$LF]"

# ---------- 4. final compile ----------
step "4 compile"
cd "$SRC"
echo "REACHED_COMPILE_STAGE"
if [ -f tr4mpass.exe ]; then
  file tr4mpass.exe
  echo "PE32 OK"
else
  echo "NO_EXE (add real build command for tr4mpass.exe here with CF and LF)"
fi
