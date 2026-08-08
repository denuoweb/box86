#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}
WORK=${ARMHF16K_MESA_WORK:-"$ROOT/armhf16k/work/mesa-pi5-private"}
OUT=${ARMHF16K_MESA_ROOT:-"$ROOT/armhf16k/private/mesa-root"}
PAGE_SIZE=${PAGE_SIZE:-16384}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-cache curl dget dpkg-source meson ninja readelf python3; do need "$x"; done

# Only install the development surface needed by the Raspberry Pi graphics
# drivers. In particular, do not install LLVM or libelf development packages.
$SUDO apt-get install -y --no-install-recommends \
    meson ninja-build pkg-config python3-mako python3-yaml python3-packaging python3-ply \
    bison flex \
    libdrm-dev:${HOST_ARCH} \
    libexpat1-dev:${HOST_ARCH} \
    libx11-dev:${HOST_ARCH} libx11-xcb-dev:${HOST_ARCH} libxext-dev:${HOST_ARCH} libxfixes-dev:${HOST_ARCH} \
    libxcb1-dev:${HOST_ARCH} libxcb-dri2-0-dev:${HOST_ARCH} libxcb-dri3-dev:${HOST_ARCH} \
    libxcb-glx0-dev:${HOST_ARCH} libxcb-present-dev:${HOST_ARCH} libxcb-randr0-dev:${HOST_ARCH} \
    libxcb-shm0-dev:${HOST_ARCH} libxcb-xfixes0-dev:${HOST_ARCH} \
    libxshmfence-dev:${HOST_ARCH} libxxf86vm-dev:${HOST_ARCH} \
    libwayland-dev:${HOST_ARCH} wayland-protocols \
    libzstd-dev:${HOST_ARCH} zlib1g-dev:${HOST_ARCH} \
    libudev-dev:${HOST_ARCH} libglvnd-dev:${HOST_ARCH}

CANDIDATE=$(apt-cache policy "mesa-libgallium:${HOST_ARCH}" | awk '/Candidate:/ {print $2; exit}')
[[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] || { echo "Cannot determine mesa-libgallium:$HOST_ARCH candidate" >&2; exit 3; }

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/fetch" "$OUT"

# Raspberry Pi OS carries Pi-specific Mesa packaging. Fetch the matching source
# directly from the Raspberry Pi archive instead of silently substituting the
# generic Debian source. Try the exact binary version first; if the binary is a
# security-revision suffix, also try the Raspberry Pi base revision.
VERSIONS=("$CANDIDATE")
case "$CANDIDATE" in
    *+deb13u*) VERSIONS+=("${CANDIDATE%%+deb13u*}") ;;
esac

DSC_URL=
for version in "${VERSIONS[@]}"; do
    url="https://archive.raspberrypi.com/debian/pool/main/m/mesa/mesa_${version}.dsc"
    if curl -fsIL "$url" >/dev/null 2>&1; then
        DSC_URL=$url
        break
    fi
done
[[ -n "$DSC_URL" ]] || {
    echo "Could not locate Raspberry Pi Mesa source matching $CANDIDATE" >&2
    echo "Refusing to build generic Debian Mesa in place of the Pi-specific source." >&2
    exit 3
}

echo "Fetching Raspberry Pi Mesa source: $DSC_URL"
(
    cd "$WORK/fetch"
    dget -u "$DSC_URL"
)
DSC=$(find "$WORK/fetch" -maxdepth 1 -type f -name 'mesa_*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[[ -n "$DSC" && -f "$DSC" ]] || { echo "Mesa .dsc was not downloaded" >&2; exit 4; }
dpkg-source -x "$DSC" "$WORK/src"

CROSS="$WORK/armhf.ini"
bash "$ROOT/scripts/armhf16k-meson-cross-file.sh" "$CROSS" >/dev/null

# Mesa's own Pi5 CI configuration uses gallium=v3d and vulkan=broadcom. LLVM
# and libelf are intentionally excluded: LLVMpipe is not needed for the Pi5
# hardware path, and Mesa documents libelf as Radeon-specific build input.
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

echo "PASS: Pi5 Mesa is 16K-compatible and its Gallium closure has no libLLVM/libelf dependency"
echo "Mesa staging root: $OUT"
