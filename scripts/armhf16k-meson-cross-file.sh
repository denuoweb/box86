#!/usr/bin/env bash
set -euo pipefail

OUT=${1:?cross-file output path required}
HOST_ARCH=${HOST_ARCH:-armhf}
PAGE_SIZE=${PAGE_SIZE:-16384}
PAGE_HEX=$(printf '0x%x' "$PAGE_SIZE")
HOST_GNU_TYPE=$(CC=arm-linux-gnueabihf-gcc dpkg-architecture -a"$HOST_ARCH" -qDEB_HOST_GNU_TYPE 2>/dev/null)
DIR=$(CDPATH= cd -- "$(dirname -- "$OUT")" && pwd)
PKGCONF="$DIR/pkg-config-$HOST_ARCH"

cat >"$PKGCONF" <<EOF
#!/bin/sh
export PKG_CONFIG_LIBDIR=/usr/lib/${HOST_GNU_TYPE}/pkgconfig:/usr/share/pkgconfig
unset PKG_CONFIG_PATH
exec /usr/bin/pkg-config "\$@"
EOF
chmod +x "$PKGCONF"

cat >"$OUT" <<EOF
[binaries]
c = '${HOST_GNU_TYPE}-gcc'
cpp = '${HOST_GNU_TYPE}-g++'
ar = '${HOST_GNU_TYPE}-ar'
strip = '${HOST_GNU_TYPE}-strip'
pkg-config = '${PKGCONF}'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'

[built-in options]
c_link_args = ['-Wl,-z,max-page-size=${PAGE_HEX}']
cpp_link_args = ['-Wl,-z,max-page-size=${PAGE_HEX}']
EOF

echo "$OUT"
