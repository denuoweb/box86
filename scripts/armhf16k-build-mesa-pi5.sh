#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: command failed (rc=$rc): $BASH_COMMAND" >&2; exit $rc' ERR

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}
WORK=${ARMHF16K_MESA_WORK:-"$ROOT/armhf16k/work/mesa-pi5-private"}
OUT=${ARMHF16K_MESA_ROOT:-"$ROOT/armhf16k/private/mesa-root"}
PAGE_SIZE=${PAGE_SIZE:-16384}
DEBIAN_SECURITY_VERSION=${ARMHF16K_MESA_DEBIAN_SECURITY_VERSION:-25.0.7-2+deb13u1}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-cache apt-get curl dget dpkg dpkg-source meson ninja patch readelf python3; do need "$x"; done

# Only install the development surface needed by Raspberry Pi V3D/V3DV. Do not
# install LLVM or libelf development packages: they are not part of the Pi5
# hardware-driver closure we are building.
$SUDO apt-get install -y --no-install-recommends \
    meson ninja-build pkg-config python3-mako python3-yaml python3-packaging python3-ply \
    bison flex patch \
    libdrm-dev:${HOST_ARCH} \
    libexpat1-dev:${HOST_ARCH} \
    libx11-dev:${HOST_ARCH} libx11-xcb-dev:${HOST_ARCH} libxext-dev:${HOST_ARCH} libxfixes-dev:${HOST_ARCH} \
    libxcb1-dev:${HOST_ARCH} libxcb-dri2-0-dev:${HOST_ARCH} libxcb-dri3-dev:${HOST_ARCH} \
    libxcb-glx0-dev:${HOST_ARCH} libxcb-present-dev:${HOST_ARCH} libxcb-randr0-dev:${HOST_ARCH} \
    libxcb-shm0-dev:${HOST_ARCH} libxcb-xfixes0-dev:${HOST_ARCH} \
    libxshmfence-dev:${HOST_ARCH} libxxf86vm-dev:${HOST_ARCH} \
    libwayland-dev:${HOST_ARCH} libwayland-egl-backend-dev:${HOST_ARCH} wayland-protocols \
    libzstd-dev:${HOST_ARCH} zlib1g-dev:${HOST_ARCH} \
    libudev-dev:${HOST_ARCH} libglvnd-dev:${HOST_ARCH}

# Do not exit awk early under pipefail: doing so can SIGPIPE apt-cache and make
# the assignment terminate the script silently with status 141.
CANDIDATE=$(apt-cache policy "mesa-libgallium:${HOST_ARCH}" | awk '/Candidate:/ {candidate=$2} END {print candidate}')
[[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] || { echo "Cannot determine mesa-libgallium:$HOST_ARCH candidate" >&2; exit 3; }
echo "Mesa ARMHF candidate: $CANDIDATE"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/pi-fetch" "$WORK/debian-security-fetch" "$OUT"

# Raspberry Pi OS carries Pi-specific Mesa changes. The archive currently keeps
# the Pi source revision separately from Debian's stable-security suffix, so
# derive the Pi base version from the installed candidate when needed.
PI_VERSION="$CANDIDATE"
case "$PI_VERSION" in
    *+deb13u*) PI_VERSION=${PI_VERSION%%+deb13u*} ;;
esac
DSC_URL="https://archive.raspberrypi.com/debian/pool/main/m/mesa/mesa_${PI_VERSION}.dsc"
if ! curl -fsIL "$DSC_URL" >/dev/null 2>&1; then
    echo "Could not locate Raspberry Pi Mesa source: $DSC_URL" >&2
    echo "Refusing to substitute generic Debian Mesa for the Pi-specific source." >&2
    exit 3
fi

echo "Fetching Raspberry Pi Mesa source: $DSC_URL"
(
    cd "$WORK/pi-fetch"
    dget -u "$DSC_URL"
)
PI_DSC=$(find "$WORK/pi-fetch" -maxdepth 1 -type f -name 'mesa_*.dsc' -print -quit)
[[ -n "$PI_DSC" && -f "$PI_DSC" ]] || { echo "Raspberry Pi Mesa .dsc was not downloaded" >&2; exit 4; }
dpkg-source -x "$PI_DSC" "$WORK/src"

# Debian Trixie 25.0.7-2+deb13u1 fixes CVE-2026-40393 with three patches.
# Apply that security delta directly to the Pi source in order. A reverse dry
# run treats an already-incorporated patch as satisfied; any other conflict is
# fatal. This avoids depending on or rewriting the Pi quilt series.
echo "Fetching Debian Mesa security source: $DEBIAN_SECURITY_VERSION"
(
    cd "$WORK/debian-security-fetch"
    apt-get --download-only --only-source source "mesa=$DEBIAN_SECURITY_VERSION"
)
SEC_DSC=$(find "$WORK/debian-security-fetch" -maxdepth 1 -type f -name 'mesa_*.dsc' -print -quit)
[[ -n "$SEC_DSC" && -f "$SEC_DSC" ]] || {
    echo "Debian Mesa security source $DEBIAN_SECURITY_VERSION is unavailable." >&2
    echo "Refusing to build a Pi Mesa runtime without the Trixie security backport." >&2
    exit 4
}
dpkg-source -x "$SEC_DSC" "$WORK/debian-security-src"

SEC_PATCH_DIR="$WORK/debian-security-src/debian/patches"
SEC_PATCHES=(
    "backport_STACK_ARRAY.patch"
    "CVE-2026-40393-part1.patch"
    "CVE-2026-40393-part2.patch"
)
for name in "${SEC_PATCHES[@]}"; do
    p="$SEC_PATCH_DIR/$name"
    [[ -f "$p" ]] || { echo "Debian security source is missing required patch: $name" >&2; exit 4; }
    if patch --dry-run -d "$WORK/src" -p1 <"$p" >/dev/null 2>&1; then
        echo "Applying Debian Mesa security patch: $name"
        patch -d "$WORK/src" -p1 <"$p"
    elif patch --dry-run -R -d "$WORK/src" -p1 <"$p" >/dev/null 2>&1; then
        echo "Security patch already present in Raspberry Pi source: $name"
    else
        echo "Security patch does not apply cleanly to Raspberry Pi Mesa source: $name" >&2
        exit 4
    fi
done

echo "Verified Debian Trixie Mesa CVE-2026-40393 security delta in Raspberry Pi source"

CROSS="$WORK/armhf.ini"
bash "$ROOT/scripts/armhf16k-meson-cross-file.sh" "$CROSS" >/dev/null

# Raspberry Pi 5 hardware uses the V3D Gallium and Broadcom V3DV paths. Build
# only that hardware closure; LLVMpipe and unrelated GPU drivers are omitted.
meson setup "$WORK/build" "$WORK/src" \
    --cross-file "$CROSS" \
    --prefix=/usr \
    --libdir=lib/arm-linux-gnueabihf \
    --buildtype=release \
    -Dgallium-drivers=v3d \
    -Dvulkan-drivers=broadcom \
    -Dllvm=disabled \
    -Dplatforms=x11,wayland \
    -Dglx=dri \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dgles1=enabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dglvnd=enabled \
    -Dbuild-tests=false

ninja -C "$WORK/build"
DESTDIR="$OUT" meson install -C "$WORK/build"

python3 "$ROOT/scripts/armhf16k-verify-tree.py" --page-size "$PAGE_SIZE" "$OUT"

mapfile -t GALLIUM < <(find "$OUT/usr/lib/arm-linux-gnueabihf" -maxdepth 1 -type f -name 'libgallium*.so*' -print | sort)
[[ ${#GALLIUM[@]} -gt 0 ]] || { echo "Mesa build did not install libgallium" >&2; exit 5; }
for so in "${GALLIUM[@]}"; do
    if readelf -dW "$so" | grep -Eq 'Shared library: \[(libLLVM|libelf)'; then
        echo "Pi5 Mesa still depends on LLVM/libelf: $so" >&2
        readelf -dW "$so" | grep NEEDED >&2 || true
        exit 6
    fi
done

echo "PASS: Pi5 Mesa is 16K-compatible, security-patched, and has no libLLVM/libelf dependency"
echo "Mesa staging root: $OUT"
