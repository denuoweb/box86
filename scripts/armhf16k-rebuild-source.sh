#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: command failed (rc=$rc): $BASH_COMMAND" >&2; exit $rc' ERR

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-}
HOST_ARCH=${HOST_ARCH:-armhf}
PAGE_SIZE=${PAGE_SIZE:-16384}
PAGE_HEX=$(printf '0x%x' "$PAGE_SIZE")
LOCAL_REVISION=${ARMHF16K_LOCAL_REVISION:-16k3}
WORK_ROOT=${ARMHF16K_WORK:-"$ROOT/armhf16k/work"}
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}
MANIFEST=${ARMHF16K_MANIFEST:-"$ROOT/armhf16k/manifest.tsv"}
SUDO=${SUDO:-sudo}

if [[ -z "$SOURCE" ]]; then
    echo "usage: $0 <Debian source package>" >&2
    exit 2
fi

case "$SOURCE" in
    zlib|libbsd|libxau|libxdmcp|libxcb) ;;
    *)
        echo "Generic cross-rebuilder is limited to the validated low-level set: zlib, libbsd, libxau, libxdmcp, libxcb" >&2
        exit 2
        ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-get apt-cache dpkg dpkg-architecture dpkg-source dpkg-buildpackage dpkg-parsechangelog dch python3 readelf; do
    need "$x"
done

HOST_GNU_TYPE=$(CC=arm-linux-gnueabihf-gcc dpkg-architecture -a"$HOST_ARCH" -qDEB_HOST_GNU_TYPE 2>/dev/null)
for x in "$HOST_GNU_TYPE-gcc" "$HOST_GNU_TYPE-g++" "$HOST_GNU_TYPE-ar" "$HOST_GNU_TYPE-strip" "$HOST_GNU_TYPE-ranlib"; do
    need "$x"
done

if ! apt-get --print-uris --only-source source "$SOURCE" >/dev/null 2>&1; then
    echo "APT cannot resolve source package '$SOURCE'. Run bootstrap first." >&2
    exit 3
fi

WORK="$WORK_ROOT/$SOURCE"
FETCH="$WORK/fetch"
SRC="$WORK/src"
rm -rf "$WORK"
mkdir -p "$FETCH" "$POOL"

echo "Installing cross-build dependencies for $SOURCE ($HOST_ARCH)"
$SUDO apt-get -y --no-install-recommends --host-architecture="$HOST_ARCH" --only-source build-dep "$SOURCE"

echo "Fetching Debian source: $SOURCE"
(
    cd "$FETCH"
    apt-get --download-only --only-source source "$SOURCE"
)

DSC=$(find "$FETCH" -maxdepth 1 -type f -name '*.dsc' -print -quit)
[[ -n "$DSC" && -f "$DSC" ]] || { echo "No .dsc found for $SOURCE" >&2; exit 4; }
dpkg-source -x "$DSC" "$SRC"

HOOK="$ROOT/armhf16k/hooks/$SOURCE.sh"
if [[ -f "$HOOK" ]]; then
    echo "Applying ARMHF16K source hook: $SOURCE"
    bash "$HOOK" "$SRC"
fi

export DEBFULLNAME=${DEBFULLNAME:-DenuoWeb ARMHF16K Builder}
export DEBEMAIL=${DEBEMAIL:-5424250+denuoweb@users.noreply.github.com}

SOURCE_VERSION=$(dpkg-parsechangelog -l"$SRC/debian/changelog" -S Version)
TARGET_BINARY=$(awk -F'\t' -v src="$SOURCE" '$2 == src {split($3,a,","); print a[1]; exit}' "$MANIFEST")
CANDIDATE=
if [[ -n "$TARGET_BINARY" ]]; then
    CANDIDATE=$(apt-cache policy "${TARGET_BINARY}:${HOST_ARCH}" 2>/dev/null | awk '/Candidate:/ {candidate=$2} END {print candidate}')
fi
if [[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" && "$CANDIDATE" == "$SOURCE_VERSION"* ]]; then
    LOCAL_VERSION="${CANDIDATE}+${LOCAL_REVISION}"
else
    LOCAL_VERSION="${SOURCE_VERSION}+${LOCAL_REVISION}"
fi

(
    cd "$SRC"
    dch --newversion "$LOCAL_VERSION" --distribution unstable --force-distribution \
        "Rebuild ARMHF binaries for ${PAGE_SIZE}-byte host-page compatibility."

    export CC="$HOST_GNU_TYPE-gcc"
    export CXX="$HOST_GNU_TYPE-g++"
    export AR="$HOST_GNU_TYPE-ar"
    export STRIP="$HOST_GNU_TYPE-strip"
    export RANLIB="$HOST_GNU_TYPE-ranlib"
    export CC_FOR_BUILD=${CC_FOR_BUILD:-gcc}
    export CXX_FOR_BUILD=${CXX_FOR_BUILD:-g++}
    export DEB_LDFLAGS_APPEND="${DEB_LDFLAGS_APPEND:+$DEB_LDFLAGS_APPEND }-Wl,-z,max-page-size=${PAGE_HEX}"
    export LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"
    export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }nocheck"

    echo "Building $SOURCE $LOCAL_VERSION for $HOST_ARCH"
    echo "CC=$CC"
    echo "LDFLAGS=$LDFLAGS"
    dpkg-buildpackage -B -us -uc -a"$HOST_ARCH"
)

mapfile -t DEBS < <(find "$WORK" -maxdepth 1 -type f -name '*.deb' ! -name '*-dbgsym_*' -print | sort)
[[ ${#DEBS[@]} -gt 0 ]] || { echo "No binary .deb files produced for $SOURCE" >&2; exit 5; }

python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size "$PAGE_SIZE" "${DEBS[@]}"
for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$POOL/"
    echo "Published: $POOL/$(basename "$deb")"
done
