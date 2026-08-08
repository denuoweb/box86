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
for x in apt-get dpkg dpkg-architecture dpkg-source dpkg-buildpackage dpkg-parsechangelog dch python3 readelf; do
    need "$x"
done

if ! dpkg --print-foreign-architectures | grep -qx "$HOST_ARCH" && [[ "$(dpkg --print-architecture)" != "$HOST_ARCH" ]]; then
    echo "$HOST_ARCH is not enabled as a foreign architecture. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

HOST_GNU_TYPE=$(dpkg-architecture -a"$HOST_ARCH" -qDEB_HOST_GNU_TYPE)
BUILD_GNU_TYPE=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)

for x in \
    "$HOST_GNU_TYPE-gcc" \
    "$HOST_GNU_TYPE-g++" \
    "$HOST_GNU_TYPE-ar" \
    "$HOST_GNU_TYPE-as" \
    "$HOST_GNU_TYPE-ld" \
    "$HOST_GNU_TYPE-nm" \
    "$HOST_GNU_TYPE-objcopy" \
    "$HOST_GNU_TYPE-objdump" \
    "$HOST_GNU_TYPE-ranlib" \
    "$HOST_GNU_TYPE-readelf" \
    "$HOST_GNU_TYPE-strip"; do
    need "$x"
done

# Resolve through apt-get's source command itself instead of inferring source
# availability from apt-cache. --print-uris performs resolution without a
# download and fails if the source package cannot be selected.
if ! apt-get --print-uris --only-source source "$SOURCE" >/dev/null 2>&1; then
    echo "APT cannot resolve source package '$SOURCE'. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

WORK="$WORK_ROOT/$SOURCE"
FETCH="$WORK/fetch"
SRC="$WORK/src"
rm -rf "$WORK"
mkdir -p "$FETCH" "$POOL"

# Resolve cross-build dependencies using Debian's host-architecture mechanism.
echo "Installing build dependencies for $SOURCE ($HOST_ARCH)"
$SUDO apt-get -y --no-install-recommends --host-architecture="$HOST_ARCH" --only-source build-dep "$SOURCE"

echo "Fetching Debian source: $SOURCE"
(
    cd "$FETCH"
    apt-get --download-only --only-source source "$SOURCE"
)

DSC=$(find "$FETCH" -maxdepth 1 -type f -name '*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
if [[ -z "$DSC" || ! -f "$DSC" ]]; then
    echo "No .dsc found after fetching $SOURCE" >&2
    exit 4
fi

dpkg-source -x "$DSC" "$SRC"

HOOK="$ROOT/armhf16k/hooks/$SOURCE.sh"
if [[ -f "$HOOK" ]]; then
    echo "Applying ARMHF16K source hook: $SOURCE"
    bash "$HOOK" "$SRC"
fi

export DEBFULLNAME=${DEBFULLNAME:-DenuoWeb ARMHF16K Builder}
export DEBEMAIL=${DEBEMAIL:-5424250+denuoweb@users.noreply.github.com}

(
    cd "$SRC"

    # Make the target toolchain explicit. Some older Debian packages partially
    # honor DEB_HOST_GNU_TYPE but allow subprojects to fall back to the native
    # compiler. Keep native compiler variables available for build-time tools.
    export CC="$HOST_GNU_TYPE-gcc"
    export CXX="$HOST_GNU_TYPE-g++"
    export CPP="$HOST_GNU_TYPE-cpp"
    export AR="$HOST_GNU_TYPE-ar"
    export AS="$HOST_GNU_TYPE-as"
    export LD="$HOST_GNU_TYPE-ld"
    export NM="$HOST_GNU_TYPE-nm"
    export OBJCOPY="$HOST_GNU_TYPE-objcopy"
    export OBJDUMP="$HOST_GNU_TYPE-objdump"
    export RANLIB="$HOST_GNU_TYPE-ranlib"
    export READELF="$HOST_GNU_TYPE-readelf"
    export STRIP="$HOST_GNU_TYPE-strip"
    export CC_FOR_BUILD=${CC_FOR_BUILD:-gcc}
    export CXX_FOR_BUILD=${CXX_FOR_BUILD:-g++}
    export AR_FOR_BUILD=${AR_FOR_BUILD:-ar}
    export LD_FOR_BUILD=${LD_FOR_BUILD:-ld}

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
    echo "build=$BUILD_GNU_TYPE host=$HOST_GNU_TYPE"
    echo "CC=$CC"
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
