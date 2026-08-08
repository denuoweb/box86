#!/usr/bin/env bash
set -euo pipefail

HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}
DEBIAN_SRC_FILE=${DEBIAN_SRC_FILE:-/etc/apt/sources.list.d/armhf16k-debian-src.sources}
DEBIAN_KEYRING=${DEBIAN_KEYRING:-}

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This bootstrap targets Debian/apt systems." >&2
    exit 2
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
CODENAME=${VERSION_CODENAME:-trixie}
if [[ "$CODENAME" != "trixie" ]]; then
    echo "Warning: expected Debian 13/trixie, detected codename '$CODENAME'." >&2
fi

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH"; then
    echo "Adding foreign architecture: $HOST_ARCH"
    $SUDO dpkg --add-architecture "$HOST_ARCH"
fi

# Test source-package resolution through the same apt-get source operation the
# rebuilder uses. --print-uris performs resolution without downloading files.
source_resolves() {
    apt-get --print-uris --only-source source "$1" >/dev/null 2>&1
}

# APT requires Signed-By to be identical for entries describing the same
# repository URI/suite. Raspberry Pi OS/Debian images can use either the .pgp
# or .gpg archive-keyring path, so inherit the path already present in the
# machine's APT configuration instead of hard-coding one spelling.
if [[ -z "$DEBIAN_KEYRING" ]]; then
    src_base=$(basename "$DEBIAN_SRC_FILE")
    if grep -Rhs --exclude="$src_base" \
        '/usr/share/keyrings/debian-archive-keyring\.pgp' \
        /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
        DEBIAN_KEYRING=/usr/share/keyrings/debian-archive-keyring.pgp
    elif grep -Rhs --exclude="$src_base" \
        '/usr/share/keyrings/debian-archive-keyring\.gpg' \
        /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
        DEBIAN_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
    elif [[ -r /usr/share/keyrings/debian-archive-keyring.pgp ]]; then
        DEBIAN_KEYRING=/usr/share/keyrings/debian-archive-keyring.pgp
    else
        DEBIAN_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
    fi
fi

if [[ ! -r "$DEBIAN_KEYRING" ]]; then
    echo "Debian archive keyring not readable: $DEBIAN_KEYRING" >&2
    exit 3
fi

# Debian source metadata is separate from binary package metadata. Modern
# Debian uses deb822 .sources files; install a source-only companion rather
# than modifying the user's existing binary repository configuration.
# Always rewrite our companion file when source resolution is unavailable so a
# previously generated entry with a mismatched Signed-By value repairs itself.
if ! source_resolves zlib; then
    echo "Enabling Debian source repositories in $DEBIAN_SRC_FILE"
    echo "Using Debian archive keyring: $DEBIAN_KEYRING"
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: ${CODENAME} ${CODENAME}-updates
Components: main contrib non-free non-free-firmware
Signed-By: ${DEBIAN_KEYRING}

Types: deb-src
URIs: http://deb.debian.org/debian-security
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: ${DEBIAN_KEYRING}
EOF
    $SUDO install -Dm644 "$tmp" "$DEBIAN_SRC_FILE"
    rm -f "$tmp"
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

if ! source_resolves zlib; then
    cat >&2 <<MSG
Debian source metadata is still unavailable after apt-get update.
Expected apt-get to resolve source package zlib from:
  $DEBIAN_SRC_FILE
Inspect it with:
  cat $DEBIAN_SRC_FILE
  apt-get --print-uris --only-source source zlib
MSG
    exit 3
fi

echo "Verified Debian source resolution: zlib"
echo "ARMHF16K build prerequisites are installed."
