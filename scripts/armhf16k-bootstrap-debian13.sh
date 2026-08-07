#!/usr/bin/env bash
set -euo pipefail

HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This bootstrap targets Debian/apt systems." >&2
    exit 2
fi

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH"; then
    echo "Adding foreign architecture: $HOST_ARCH"
    $SUDO dpkg --add-architecture "$HOST_ARCH"
fi

$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends \
    build-essential \
    crossbuild-essential-armhf \
    devscripts \
    debhelper \
    dpkg-dev \
    fakeroot \
    equivs \
    python3 \
    binutils \
    gzip \
    apt-utils

if ! apt-cache showsrc zlib >/dev/null 2>&1; then
    cat >&2 <<'MSG'
No deb-src entries are enabled. The ARMHF16K rebuilder uses Debian source
packages, so enable source repositories matching your Debian 13 binary
repositories, run `sudo apt-get update`, and rerun this script.
MSG
    exit 3
fi

echo "ARMHF16K build prerequisites are installed."
