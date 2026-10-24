#!/usr/bin/env bash
set -uo pipefail

PREFIX="$HOME/win32"
SRC="$HOME/bsrc"
TREE="$(ls -d "$SRC"/openssl-3.0.* 2>/dev/null | head -1)"
[ -n "${TREE:-}" ] || { echo "OPENSSL_TREE_MISSING"; exit 1; }

cd "$TREE" || exit 1
echo "using $TREE"

# install_dev installs the GENERATED headers (opensslv.h, configuration.h, ...)
# which a plain cp of include/openssl/*.h misses.
make install_dev 2>&1 | tail -5 || true

for h in opensslv.h configuration.h opensslconf.h err.h ssl.h evp.h; do
  if [ -f "$PREFIX/include/openssl/$h" ]; then
    echo "HDR OK      $h"
  else
    echo "HDR MISSING $h"
  fi
done

[ -f "$PREFIX/include/openssl/configuration.h" ] || {
  cp -f include/openssl/configuration.h "$PREFIX/include/openssl/" 2>/dev/null && echo "copied configuration.h"
}

if [ -f "$PREFIX/include/openssl/configuration.h" ] && [ -f "$PREFIX/include/openssl/opensslv.h" ]; then
  echo "OPENSSL_HEADERS OK"
else
  echo "OPENSSL_HEADERS INCOMPLETE"
  exit 1
fi
