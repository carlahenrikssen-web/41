#!/usr/bin/env bash
set -uo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
JOBS="$(nproc 2>/dev/null || echo 4)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_ALLOW_CROSS=1
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$SRC"
RESULTS=()

run_stage() {
  local name="$1"; shift
  echo; echo "########## START $name ##########"
  if ( set -e; "$@" ); then
    RESULTS+=("OK    $name"); echo "########## OK $name ##########"
  else
    RESULTS+=("FAIL  $name"); echo "########## FAIL $name ##########"
  fi
}

fetch() {
  local d="$1" u="$2" t
  cd "$SRC" || return 1
  t="$(basename "$u")"
  [ -s "$t" ] || wget -q --tries=3 -O "$t" "$u" || return 1
  rm -rf "$d"
  tar xf "$t" || return 1
  [ -d "$d" ]
}

openssl_stage() {
  local v
  for v in 3.0.15 3.0.13 3.0.11; do
    if fetch "openssl-$v" "https://github.com/openssl/openssl/releases/download/openssl-$v/openssl-$v.tar.gz"; then
      cd "$SRC/openssl-$v"
      ./Configure mingw no-shared no-tests no-docs \
        --prefix="$PREFIX" --cross-compile-prefix="$HOST-" > /dev/null
      make -j"$JOBS" build_libs
      make install_dev > /dev/null 2>&1 || true
      mkdir -p "$PREFIX/include/openssl" "$PREFIX/lib"
      cp -f libcrypto.a libssl.a "$PREFIX/lib/" 2>/dev/null || true
      cp -f include/openssl/*.h "$PREFIX/include/openssl/" 2>/dev/null || true
      printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: OpenSSL\nDescription: OpenSSL\nVersion: %s\nLibs: -L${libdir} -lssl -lcrypto -lws2_32 -lcrypt32 -lgdi32 -ladvapi32 -luser32\nCflags: -I${includedir}\n' \
        "$PREFIX" "$v" > "$PREFIX/lib/pkgconfig/openssl.pc"
      return 0
    fi
  done
  return 1
}

autotools_stage() {
  local name="$1" repo="$2"; shift 2
  cd "$SRC" || return 1
  rm -rf "$name"
  git clone --depth 1 "$repo" "$name" || return 1
  cd "$name" || return 1
  if [ ! -x ./configure ]; then
    ( NOCONFIGURE=1 ./autogen.sh || ./bootstrap || ./buildconf ) > /dev/null 2>&1 || true
  fi
  ./configure --host="$HOST" --prefix="$PREFIX" "$@"
  make -j"$JOBS"
  make install
}

s_libusb()  { autotools_stage libusb https://github.com/libusb/libusb.git \
                --disable-static --enable-shared; }
s_plist()   { autotools_stage libplist https://github.com/libimobiledevice/libplist.git \
                --disable-static --enable-shared --without-cython; }
s_glue()    { autotools_stage libimobiledevice-glue https://github.com/libimobiledevice/libimobiledevice-glue.git \
                --disable-static --enable-shared; }
s_usbmuxd() { autotools_stage libusbmuxd https://github.com/libimobiledevice/libusbmuxd.git \
                --disable-static --enable-shared --without-cython; }
s_irecv()   { autotools_stage libirecovery https://github.com/libimobiledevice/libirecovery.git \
                --disable-static --enable-shared; }
s_imd()     { autotools_stage libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git \
                --disable-static --enable-shared --without-cython; }
s_ssh2()    { autotools_stage libssh2 https://github.com/libssh2/libssh2.git \
                --disable-static --enable-shared --with-crypto=openssl; }
s_curl()    { autotools_stage curl https://github.com/curl/curl.git \
                --disable-static --enable-shared --with-schannel --without-ssl \
                --without-libpsl --without-zlib --disable-ldap --disable-threaded-resolver; }

run_stage openssl        openssl_stage
run_stage libusb         s_libusb
run_stage libplist       s_plist
run_stage glue           s_glue
run_stage libusbmuxd     s_usbmuxd
run_stage libirecovery   s_irecv
run_stage libimobiledevice s_imd
run_stage libssh2        s_ssh2
run_stage curl           s_curl

echo; echo "########## SUMMARY ##########"
pkg-config --exists libimobiledevice-1.0 libirecovery-1.0 libusb-1.0 libplist-2.0 openssl libcurl libssh2 \
  && echo "ALL_PKG_CONFIG_FOUND" || echo "SOME_PKG_CONFIG_MISSING"
for p in openssl libusb-1.0 libplist-2.0 libirecovery-1.0 libimobiledevice-1.0 libssh2 libcurl; do
  if pkg-config --exists "$p"; then
    echo "OK       $p $(pkg-config --modversion "$p")"
  else
    echo "MISSING  $p"
  fi
done
mkdir -p win32dll && cp -f "$PREFIX/bin/"*.dll win32dll/ 2>/dev/null || true
