#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-}
HOST_ARCH=${HOST_ARCH:-armhf}
PAGE_SIZE=${PAGE_SIZE:-16384}
PAGE_HEX=$(printf '0x%x' "$PAGE_SIZE")
SUDO=${SUDO:-sudo}
WORK_ROOT=${ARMHF16K_WORK:-"$ROOT/armhf16k/work"}
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}

if [[ -z "$SOURCE" ]]; then
    echo "usage: $0 <Debian source package>" >&2
    exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-get apt-cache dpkg dpkg-source dpkg-buildpackage dpkg-parsechangelog dch python3 readelf; do
    need "$x"
done

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH" && [[ "$(dpkg --print-architecture)" != "$HOST_ARCH" ]]; then
    echo "$HOST_ARCH is not enabled as a foreign architecture. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

# apt-cache showsrc exits successfully even when no source record was printed.
# Require an exact source-package record so we fail before apt-get build-dep
# with a misleading "Unable to find a source package" error.
if ! apt-cache showsrc --only-source "$SOURCE" 2>/dev/null | grep -Fqx "Package: $SOURCE"; then
    echo "APT has no source record for '$SOURCE'. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

WORK="$WORK_ROOT/$SOURCE"
FETCH="$WORK/fetch"
SRC="$WORK/src"
rm -rf "$WORK"
mkdir -p "$FETCH" "$POOL"

# Resolve cross-build dependencies using Debian's host-architecture mechanism.
echo "Installing build dependencies for $SOURCE ($HOST_ARCH)"
$SUDO apt-get build-dep -y --no-install-recommends --host-architecture="$HOST_ARCH" --only-source "$SOURCE"

echo "Fetching Debian source: $SOURCE"
(
    cd "$FETCH"
    apt-get source --download-only --only-source "$SOURCE"
)

DSC=$(find "$FETCH" -maxdepth 1 -type f -name '*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
if [[ -z "$DSC" || ! -f "$DSC" ]]; then
    echo "No .dsc found after fetching $SOURCE" >&2
    exit 4
fi

dpkg-source -x "$DSC" "$SRC"

export DEBFULLNAME=${DEBFULLNAME:-DenuoWeb ARMHF16K Builder}
export DEBEMAIL=${DEBEMAIL:-5424250+denuoweb@users.noreply.github.com}

(
    cd "$SRC"
    # Build a version newer than the Debian base while preserving the source package.
    dch --local +16k --distribution unstable --force-distribution \
        "Rebuild ARMHF binaries for ${PAGE_SIZE}-byte host-page compatibility."

    # User-side dpkg-buildflags extension. Also export the resolved LDFLAGS for
    # build systems that consume the environment directly instead of querying
    # dpkg-buildflags themselves.
    export DEB_LDFLAGS_APPEND="${DEB_LDFLAGS_APPEND:+$DEB_LDFLAGS_APPEND }-Wl,-z,max-page-size=${PAGE_HEX}"
    export LDFLAGS="$(dpkg-buildflags --get LDFLAGS)"

    case " ${DEB_BUILD_OPTIONS:-} " in
        *" nocheck "*) ;;
        *) export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }nocheck" ;;
    esac

    echo "Building architecture-dependent $SOURCE binaries for $HOST_ARCH"
    echo "LDFLAGS=$LDFLAGS"
    dpkg-buildpackage -B -us -uc -a"$HOST_ARCH"
)

mapfile -t DEBS < <(find "$WORK" -maxdepth 1 -type f -name '*.deb' ! -name '*-dbgsym_*' -print | sort)
if [[ ${#DEBS[@]} -eq 0 ]]; then
    echo "No binary .deb files produced for $SOURCE" >&2
    exit 5
fi

# Do not publish a source build unless every ARM ELF shipped by its binary
# packages satisfies the 16K PT_LOAD congruence invariant.
python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size "$PAGE_SIZE" "${DEBS[@]}"

for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$POOL/"
    echo "Published: $POOL/$(basename "$deb")"
done
