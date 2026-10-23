#!/usr/bin/env bash
set -euo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
JOBS="$(nproc)"
mkdir -p "$PREFIX" "$SRC"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_ALLOW_CROSS=1

log() { echo; echo "########## $* ##########"; }
probe() { if pkg-config --exists "$1" 2>/dev/null; then echo "OK  $1 $(pkg-config --modversion "$1")"; else echo "MISSING  $1"; fi; }

# ---------- openssl (static, mingw) ----------
log "openssl"
cd "$SRC"
for v in 3.0.15 3.0.13 3.0.11 3.0.8; do
  rm -rf "openssl-$v" "openssl-$v.tar.gz"
  if wget -q "https://www.openssl.org/source/openssl-$v.tar.gz"; then
    tar xzf "openssl-$v.tar.gz" && echo "using $v" && break
  fi
done
cd openssl-3.0.*
./Configure mingw no-shared no-tests --prefix="$PREFIX" --cross-compile-prefix="$HOST-"
make -j"$JOBS" build_libs
make install_dev
probe openssl

# ---------- libusb ----------
log "libusb"
cd "$SRC"
rm -rf libusb
git clone --depth 1 https://github.com/libusb/libusb.git
cd libusb
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared
make -j"$JOBS"
make install
probe libusb-1.0

# ---------- libplist ----------
log "libplist"
cd "$SRC"
rm -rf libplist
git clone --depth 1 https://github.com/libimobiledevice/libplist.git
cd libplist
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared --without-cython
make -j"$JOBS"
make install
probe libplist-2.0

# ---------- libimobiledevice-glue ----------
log "libimobiledevice-glue"
cd "$SRC"
rm -rf libimobiledevice-glue
git clone --depth 1 https://github.com/libimobiledevice/libimobiledevice-glue.git
cd libimobiledevice-glue
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared
make -j"$JOBS"
make install

# ---------- libusbmuxd ----------
log "libusbmuxd"
cd "$SRC"
rm -rf libusbmuxd
git clone --depth 1 https://github.com/libimobiledevice/libusbmuxd.git
cd libusbmuxd
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared --without-cython
make -j"$JOBS"
make install
probe libusbmuxd-2.0

# ---------- libirecovery ----------
log "libirecovery"
cd "$SRC"
rm -rf libirecovery
git clone --depth 1 https://github.com/libimobiledevice/libirecovery.git
cd libirecovery
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared
make -j"$JOBS"
make install
probe libirecovery-1.0

# ---------- libimobiledevice ----------
log "libimobiledevice"
cd "$SRC"
rm -rf libimobiledevice
git clone --depth 1 https://github.com/libimobiledevice/libimobiledevice.git
cd libimobiledevice
./autogen.sh
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared --without-cython
make -j"$JOBS"
make install
probe libimobiledevice-1.0

# ---------- libssh2 (needs openssl) ----------
log "libssh2"
cd "$SRC"
rm -rf libssh2
git clone --depth 1 https://github.com/libssh2/libssh2.git
cd libssh2
./buildconf
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared \
  --with-crypto=openssl --with-openssl --without-libz
make -j"$JOBS"
make install
probe libssh2

# ---------- curl (schannel: no openssl needed) ----------
log "curl"
cd "$SRC"
rm -rf curl
git clone --depth 1 https://github.com/curl/curl.git
cd curl
./buildconf
./configure --host="$HOST" --prefix="$PREFIX" --disable-static --enable-shared \
  --with-schannel --without-ssl --without-libssh2 --without-zlib --disable-ldap
make -j"$JOBS"
make install
probe libcurl

log "SUMMARY"
for p in openssl libusb-1.0 libplist-2.0 libirecovery-1.0 libimobiledevice-1.0 libssh2 libcurl; do probe "$p"; done
mkdir -p "$GITHUB_WORKSPACE/win32dll"
cp -v "$PREFIX/bin/"*.dll "$GITHUB_WORKSPACE/win32dll/" || true
