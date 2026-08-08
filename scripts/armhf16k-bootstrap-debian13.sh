#!/usr/bin/env bash
set -euo pipefail

HOST_ARCH=${HOST_ARCH:-armhf}
BUILD_ARCH=${BUILD_ARCH:-$HOST_ARCH}
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
SBUILD_TARBALL=${ARMHF16K_SBUILD_TARBALL:-"$HOME/.cache/sbuild/${CODENAME}-${BUILD_ARCH}.tar.gz"}
if [[ "$CODENAME" != "trixie" ]]; then
    echo "Warning: expected Debian 13/trixie, detected codename '$CODENAME'." >&2
fi

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH" && [[ "$(dpkg --print-architecture)" != "$HOST_ARCH" ]]; then
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
    devscripts \
    dpkg-dev \
    fakeroot \
    python3 \
    binutils \
    gzip \
    apt-utils \
    sbuild \
    debootstrap \
    mmdebstrap \
    uidmap \
    arch-test

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

if ! unshare -Ur true >/dev/null 2>&1; then
    cat >&2 <<'MSG'
Unprivileged user namespaces are unavailable, but ARMHF16K uses sbuild's
unshare backend to isolate build dependencies from the host system.
Enable them and rerun bootstrap, for example:
  sudo sysctl -w kernel.unprivileged_userns_clone=1
MSG
    exit 4
fi

# Prefer a native ARMHF build root over arm64->armhf cross-building. Debian's
# cross dependency graph is not fully satisfiable for packages such as
# elfutils, while this Raspberry Pi kernel/CPU can execute ARMHF directly.
if ! arch-test "$BUILD_ARCH" >/dev/null 2>&1; then
    cat >&2 <<MSG
The current machine/kernel cannot execute Debian $BUILD_ARCH binaries natively.
ARMHF16K intentionally uses a native $BUILD_ARCH sbuild root to avoid Debian
cross-build dependency limitations. Check with:
  arch-test $BUILD_ARCH
MSG
    exit 5
fi

echo "Verified native execution support: $BUILD_ARCH"

if [[ ! -f "$SBUILD_TARBALL" ]]; then
    echo "Creating isolated native $BUILD_ARCH sbuild base: $SBUILD_TARBALL"
    mkdir -p "$(dirname "$SBUILD_TARBALL")"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    sbuild-createchroot \
        --chroot-mode=unshare \
        --arch="$BUILD_ARCH" \
        --components=main \
        --make-sbuild-tarball="$SBUILD_TARBALL" \
        "$CODENAME" "$tmpdir" http://deb.debian.org/debian
    rm -rf "$tmpdir"
    trap - EXIT
fi

[[ -r "$SBUILD_TARBALL" ]] || { echo "sbuild tarball was not created: $SBUILD_TARBALL" >&2; exit 6; }

echo "Verified isolated native sbuild base: $SBUILD_TARBALL"
echo "ARMHF16K build prerequisites are installed."
