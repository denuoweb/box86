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
PROOT_BASE=${ARMHF16K_PROOT_BASE:-"$HOME/.cache/armhf16k/${CODENAME}-${HOST_ARCH}-proot.tar.gz"}

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

if [[ ! -r "$DEBIAN_KEYRING" ]]; then
    echo "Debian archive keyring not readable: $DEBIAN_KEYRING" >&2
    exit 3
fi

if ! source_resolves zlib; then
    echo "Enabling Debian source repositories in $DEBIAN_SRC_FILE"
    echo "Using Debian archive keyring: $DEBIAN_KEYRING"
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
types: deb-src
EOF
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
    tar \
    apt-utils \
    debootstrap \
    proot \
    qemu-user

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

command -v proot >/dev/null 2>&1 || { echo "proot is unavailable" >&2; exit 4; }
command -v qemu-arm >/dev/null 2>&1 || { echo "qemu-arm is unavailable" >&2; exit 4; }

proot_base_valid() {
    [[ -r "$PROOT_BASE" ]] || return 1
    tar -tzf "$PROOT_BASE" 2>/dev/null | grep -Eq '^(\./)?etc/debian_version$' || return 1
    tar -tzf "$PROOT_BASE" 2>/dev/null | grep -Eq '^(\./)?(bin|usr/bin)/(sh|dash)$' || return 1
    tar -tzf "$PROOT_BASE" 2>/dev/null | grep -Eq '^(\./)?usr/bin/dpkg$'
}

if [[ -e "$PROOT_BASE" ]] && ! proot_base_valid; then
    echo "Removing incomplete PRoot base: $PROOT_BASE"
    rm -f -- "$PROOT_BASE"
fi

if ! proot_base_valid; then
    echo "Creating ARMHF PRoot base: $PROOT_BASE"
    mkdir -p "$(dirname "$PROOT_BASE")"
    tmpdir=$(mktemp -d)

    cleanup_tmpdir() {
        if [[ -n "${tmpdir:-}" && -d "$tmpdir" ]]; then
            $SUDO rm -rf --one-file-system -- "$tmpdir" || true
        fi
    }
    trap cleanup_tmpdir EXIT INT TERM

    # First stage only downloads and extracts ARMHF packages. It does not need
    # to execute target binaries, which is important because stock ARMHF ELFs
    # can be 4K-linked and rejected by this 16K-page kernel.
    $SUDO debootstrap \
        --foreign \
        --arch="$HOST_ARCH" \
        --variant=buildd \
        --include=fakeroot,build-essential \
        --components=main \
        "$CODENAME" "$tmpdir" http://deb.debian.org/debian

    # Separate QEMU from PRoot before combining them. If either of these fails,
    # the host qemu-arm linux-user path itself cannot execute the extracted
    # ARMHF base and PRoot is not the relevant fault domain.
    if ! qemu-arm -L "$tmpdir" "$tmpdir/bin/true"; then
        echo "Direct qemu-arm smoke test failed for ARMHF /bin/true" >&2
        exit 5
    fi
    if ! qemu-arm -L "$tmpdir" "$tmpdir/bin/sh" -c 'exit 0'; then
        echo "Direct qemu-arm smoke test failed for ARMHF /bin/sh" >&2
        exit 5
    fi
    echo "Verified direct qemu-arm execution of extracted ARMHF base"

    # PRoot's -q mode inserts qemu-arm in front of guest execution and handles
    # path translation. Disable PRoot's seccomp acceleration for this path:
    # ptrace/seccomp acceleration can conflict with emulated guest execution on
    # some kernels. This is build-time scaffolding only.
    $SUDO env PROOT_NO_SECCOMP=1 proot \
        -S "$tmpdir" \
        -q qemu-arm \
        -w / \
        /bin/sh /debootstrap/debootstrap --second-stage

    cat <<EOF | $SUDO tee "$tmpdir/etc/apt/sources.list" >/dev/null
deb http://deb.debian.org/debian ${CODENAME} main
deb-src http://deb.debian.org/debian ${CODENAME} main
deb http://deb.debian.org/debian ${CODENAME}-updates main
deb-src http://deb.debian.org/debian ${CODENAME}-updates main
deb http://deb.debian.org/debian-security ${CODENAME}-security main
deb-src http://deb.debian.org/debian-security ${CODENAME}-security main
EOF

    arch=$($SUDO env PROOT_NO_SECCOMP=1 proot -S "$tmpdir" -q qemu-arm /usr/bin/dpkg --print-architecture)
    if [[ "$arch" != "$HOST_ARCH" ]]; then
        echo "PRoot base reported architecture '$arch', expected '$HOST_ARCH'" >&2
        exit 5
    fi
    echo "Verified PRoot guest execution: $arch via qemu-arm"

    tmpbase="${PROOT_BASE}.tmp.$$"
    $SUDO tar \
        --numeric-owner \
        --one-file-system \
        --exclude='./dev/*' \
        --exclude='./proc/*' \
        --exclude='./sys/*' \
        --exclude='./tmp/*' \
        --exclude='./run/*' \
        -C "$tmpdir" -czf "$tmpbase" .
    $SUDO chown "$(id -u):$(id -g)" "$tmpbase"
    mv -f "$tmpbase" "$PROOT_BASE"

    cleanup_tmpdir
    tmpdir=
    trap - EXIT INT TERM
fi

if ! proot_base_valid; then
    echo "PRoot base is missing or incomplete: $PROOT_BASE" >&2
    exit 6
fi

echo "Verified ARMHF PRoot base: $PROOT_BASE"
echo "ARMHF16K build prerequisites are installed."
