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

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH" && [[ "$(dpkg --print-architecture)" != "$HOST_ARCH" ]]; then
    echo "Adding foreign architecture: $HOST_ARCH"
    $SUDO dpkg --add-architecture "$HOST_ARCH"
fi

source_resolves() {
    apt-get --print-uris --only-source source "$1" >/dev/null 2>&1
}

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

[[ -r "$DEBIAN_KEYRING" ]] || { echo "Debian archive keyring not readable: $DEBIAN_KEYRING" >&2; exit 3; }

if ! source_resolves zlib; then
    echo "Enabling Debian source repositories in $DEBIAN_SRC_FILE"
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
    python3-mako \
    python3-yaml \
    python3-packaging \
    meson \
    ninja-build \
    pkg-config \
    bison \
    flex \
    curl \
    ca-certificates \
    binutils \
    gzip \
    tar \
    apt-utils

if ! source_resolves zlib; then
    echo "Debian source metadata is unavailable after apt-get update." >&2
    exit 3
fi

for x in \
    arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++ \
    arm-linux-gnueabihf-ar arm-linux-gnueabihf-strip \
    meson ninja pkg-config; do
    command -v "$x" >/dev/null 2>&1 || { echo "Missing build tool: $x" >&2; exit 4; }
done

cat <<'MSG'
ARMHF16K build prerequisites are installed.
The graphics runtime is cross-built with native arm64 build tools and an ARMHF
toolchain. PRoot/sbuild/QEMU are not part of the supported build path.
MSG
