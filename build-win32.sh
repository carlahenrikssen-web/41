#!/usr/bin/env bash
set -uo pipefail

HOST=i686-w64-mingw32
PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
LOGDIR="$GITHUB_WORKSPACE/logs"
JOBS="$(nproc 2>/dev/null || echo 4)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_ALLOW_CROSS=1
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$SRC" "$LOGDIR"
RESULTS=()

# diag.txt run #8: ld failed with -lIphlpapi (capital I). MinGW ships it
# lowercase; provide an exact-case copy so any spelling links.
cp -n /usr/i686-w64-mingw32/lib/libiphlpapi.a "$PREFIX/lib/libIphlpapi.a" 2>/dev/null || true

run_stage() {
  local name="$1"; shift
  local lf="$LOGDIR/$name.log"
  echo "########## START $name ##########"
  if ( set -e; "$@" ) > "$lf" 2>&1; then
    RESULTS+=("OK|$name"); echo "########## OK $name ##########"
  else
    RESULTS+=("FAIL|$name")
    echo "########## FAIL $name ##########"
    tail -25 "$lf" || true
    grep -nE 'error:|Error |No package|not found|undefined reference|cannot find|fatal' "$lf" | tail -10 || true
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
      cd "$SRC/openssl-$v" || return 1
      ./Configure mingw no-shared no-tests no-docs \
        --prefix="$PREFIX" --cross-compile-prefix="$HOST-" > /dev/null
      make -j"$JOBS" build_libs
      mkdir -p "$PREFIX/lib" "$PREFIX/include/openssl"
      cp -f libcrypto.a libssl.a "$PREFIX/lib/" 2>/dev/null || true
      cp -f include/openssl/*.h "$PREFIX/include/openssl/" 2>/dev/null || true
      printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: OpenSSL\nDescription: OpenSSL\nVersion: %s\nLibs: -L${libdir} -lssl -lcrypto\nLibs.private: -lws2_32 -lcrypt32 -lgdi32 -ladvapi32 -luser32\nCflags: -I${includedir}\n' \
        "$PREFIX" "$v" > "$PREFIX/lib/pkgconfig/openssl.pc"
      printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libcrypto\nDescription: OpenSSL libcrypto\nVersion: %s\nLibs: -L${libdir} -lcrypto\nLibs.private: -lws2_32 -lcrypt32 -lgdi32 -ladvapi32 -luser32\nCflags: -I${includedir}\n' \
        "$PREFIX" "$v" > "$PREFIX/lib/pkgconfig/libcrypto.pc"
      printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libssl\nDescription: OpenSSL libssl\nVersion: %s\nLibs: -L${libdir} -lssl\nLibs.private: -lcrypto -lws2_32 -lcrypt32 -lgdi32 -ladvapi32 -luser32\nCflags: -I${includedir}\n' \
        "$PREFIX" "$v" > "$PREFIX/lib/pkgconfig/libssl.pc"
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
  ./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" "$@"
  make -j"$JOBS"
  make install
}

# Library-only install: library + headers + .pc install fine;
# only the bundled command-line TOOL fails to link (run #8 diag).
libonly_install() {
  make -C src install
  make -C include install
}

s_libusb() { autotools_stage libusb https://github.com/libusb/libusb.git --disable-static --enable-shared; }
s_plist()  { autotools_stage libplist https://github.com/libimobiledevice/libplist.git --disable-static --enable-shared --without-cython; }
s_glue()   { autotools_stage libimobiledevice-glue https://github.com/libimobiledevice/libimobiledevice-glue.git --disable-static --enable-shared; }

s_usbmuxd() {
  autotools_stage libusbmuxd https://github.com/libimobiledevice/libusbmuxd.git \
    --enable-static --disable-shared --without-cython \
    LDFLAGS="-L$PREFIX/lib -lws2_32 -liphlpapi" &&
  cd "$SRC/libusbmuxd" && libonly_install
}

s_irecv() {
  autotools_stage libirecovery https://github.com/libimobiledevice/libirecovery.git \
    --enable-static --disable-shared \
    LDFLAGS="-L$PREFIX/lib -lws2_32 -liphlpapi" &&
  cd "$SRC/libirecovery" && libonly_install
}

s_curl() {
  cd "$SRC" || return 1
  rm -rf curl
  git clone --depth 1 https://github.com/curl/curl.git curl || return 1
  cd curl || return 1
  [ -x ./configure ] || ./buildconf > /dev/null 2>&1 || true
  ./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" \
    --enable-static --disable-shared --with-schannel --without-ssl \
    --without-libpsl --without-zlib --without-brotli --without-zstd \
    --disable-ldap --disable-threaded-resolver --disable-manual \
    --without-libidn2 --without-nghttp2 --disable-aws --disable-mqtt \
    LDFLAGS="-L$PREFIX/lib -lws2_32 -lsecur32 -lcrypt32 -lbcrypt -ladvapi32"
  make -j"$JOBS" -C lib
  make -j"$JOBS" -C include
  make install -C lib
  make install -C include
  [ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ] || printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: libcurl\nDescription: curl\nVersion: 8\nLibs: -L${libdir} -lcurl\nLibs.private: -lws2_32 -lsecur32 -lcrypt32 -lbcrypt -ladvapi32\nCflags: -I${includedir}\n' \
    "$PREFIX" > "$PREFIX/lib/pkgconfig/libcurl.pc"
  return 0
}

# diag2.txt run #9: tatsu failed ONLY on "libcurl >= 7.0 ... not found",
# because curl built AFTER tatsu. Fix = stage order (curl first).
s_tatsu() {
  autotools_stage libtatsu https://github.com/libimobiledevice/libtatsu.git \
    --enable-static --disable-shared
}

s_imd() {
  autotools_stage libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git \
    --enable-static --disable-shared --without-cython \
    LDFLAGS="-L$PREFIX/lib -lws2_32 -lcrypt32 -liphlpapi"
}

# diag2.txt run #9: openssl backend not detected through our hand-written .pc.
# wincng = Windows native crypto (bcrypt/crypt32), needs NO openssl at all.
s_ssh2() {
  local v=1.11.1
  fetch "libssh2-$v" "https://github.com/libssh2/libssh2/releases/download/libssh2-$v/libssh2-$v.tar.gz" || return 1
  cd "$SRC/libssh2-$v" || return 1
  ./configure --host="$HOST" --build="$(gcc -dumpmachine)" --prefix="$PREFIX" \
    --enable-static --disable-shared --with-crypto=wincng \
    --without-libz --disable-examples-build \
    LDFLAGS="-L$PREFIX/lib"
  make -j"$JOBS"
  make install
}

run_stage openssl            openssl_stage
run_stage libusb             s_libusb
run_stage libplist           s_plist
run_stage glue               s_glue
run_stage libusbmuxd         s_usbmuxd
run_stage libirecovery       s_irecv
run_stage curl               s_curl
run_stage tatsu              s_tatsu
run_stage libimobiledevice   s_imd
run_stage libssh2            s_ssh2

{
  echo "########## SUMMARY ##########"
  for r in "${RESULTS[@]}"; do echo "${r/|/  }"; done
  echo
  for p in openssl libusb-1.0 libplist-2.0 libirecovery-1.0 libimobiledevice-1.0 libssh2 libcurl; do
    if pkg-config --exists "$p"; then
      echo "OK       $p $(pkg-config --modversion "$p")"
    else
      echo "MISSING  $p"
    fi
  done
} | tee "$LOGDIR/summary.txt"

mkdir -p win32dll && cp -f "$PREFIX/bin/"*.dll win32dll/ 2>/dev/null || true
