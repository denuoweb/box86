#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}
WORK=${ARMHF16K_MESA_WORK:-"$ROOT/armhf16k/work/mesa-pi5-private"}
OUT=${ARMHF16K_MESA_ROOT:-"$ROOT/armhf16k/private/mesa-root"}
PAGE_SIZE=${PAGE_SIZE:-16384}
DEBIAN_SECURITY_VERSION=${ARMHF16K_MESA_DEBIAN_SECURITY_VERSION:-25.0.7-2+deb13u1}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-cache apt-get curl dget dpkg dpkg-source meson ninja readelf python3; do need "$x"; done

# Only install the development surface needed by Raspberry Pi V3D/V3DV. Do not
# install LLVM or libelf development packages: they are not part of the Pi5
# hardware-driver closure we are building.
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
PI_DSC=$(find "$WORK/pi-fetch" -maxdepth 1 -type f -name 'mesa_*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[[ -n "$PI_DSC" && -f "$PI_DSC" ]] || { echo "Raspberry Pi Mesa .dsc was not downloaded" >&2; exit 4; }
dpkg-source -x "$PI_DSC" "$WORK/src"

# Debian Trixie 25.0.7-2+deb13u1 fixes CVE-2026-40393 with three quilt
# patches. Pi's rpt4 source is based on the same 25.0.7 upstream but the public
# Pi source archive does not carry the +deb13u1 source suffix, so explicitly
# layer those stable-security patches onto the Pi tree. Never silently fall
# back to the pre-security Pi source alone.
echo "Fetching Debian Mesa security source: $DEBIAN_SECURITY_VERSION"
(
    cd "$WORK/debian-security-fetch"
    apt-get --download-only --only-source source "mesa=$DEBIAN_SECURITY_VERSION"
)
SEC_DSC=$(find "$WORK/debian-security-fetch" -maxdepth 1 -type f -name 'mesa_*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[[ -n "$SEC_DSC" && -f "$SEC_DSC" ]] || {
    echo "Debian Mesa security source $DEBIAN_SECURITY_VERSION is unavailable." >&2
    echo "Refusing to build a Pi Mesa runtime without the Trixie security backport." >&2
    exit 4
}
dpkg-source -x "$SEC_DSC" "$WORK/debian-security-src"

python3 - "$WORK/debian-security-src" "$WORK/src" <<'PY'
from pathlib import Path
import shutil
import sys

security = Path(sys.argv[1]) / "debian/patches"
target = Path(sys.argv[2]) / "debian/patches"
required = [
    "backport_STACK_ARRAY.patch",
    "CVE 2026 40393 part1.patch",
    "CVE 2026 40393 part2.patch",
]
series = target / "series"
lines = series.read_text().splitlines() if series.exists() else []
for name in required:
    src = security / name
    if not src.is_file():
        raise SystemExit(f"Debian security source is missing required patch: {name}")
    dst = target / name
    shutil.copy2(src, dst)
    if name not in lines:
        lines.append(name)
series.write_text("\n".join(lines) + "\n")
print("Applied Debian Trixie Mesa CVE-2026-40393 patch series to Raspberry Pi source")
PY

# Apply the newly appended security quilt patches to the unpacked Pi source.
(
    cd "$WORK/src"
    QUILT_PATCHES=debian/patches quilt push -a
)

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
