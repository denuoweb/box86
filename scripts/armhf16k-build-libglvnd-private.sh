#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}
WORK=${ARMHF16K_GLVND_WORK:-"$ROOT/armhf16k/work/libglvnd-private"}
OUT=${ARMHF16K_GLVND_ROOT:-"$ROOT/armhf16k/private/glvnd-root"}
PAGE_SIZE=${PAGE_SIZE:-16384}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-get dpkg-source meson ninja python3; do need "$x"; done

$SUDO apt-get install -y --no-install-recommends \
    meson ninja-build pkg-config python3-setuptools \
    libx11-dev:${HOST_ARCH} libxext-dev:${HOST_ARCH} x11proto-dev

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/fetch" "$OUT"
(
    cd "$WORK/fetch"
    apt-get --download-only --only-source source libglvnd
)
DSC=$(find "$WORK/fetch" -maxdepth 1 -type f -name 'libglvnd_*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
[[ -n "$DSC" && -f "$DSC" ]] || { echo "libglvnd .dsc was not downloaded" >&2; exit 3; }
dpkg-source -x "$DSC" "$WORK/src"

CROSS="$WORK/armhf.ini"
bash "$ROOT/scripts/armhf16k-meson-cross-file.sh" "$CROSS" >/dev/null

meson setup "$WORK/build" "$WORK/src" \
    --cross-file "$CROSS" \
    --prefix=/usr \
    --libdir=lib/arm-linux-gnueabihf \
    --buildtype=release

ninja -C "$WORK/build"
DESTDIR="$OUT" meson install -C "$WORK/build"

python3 "$ROOT/scripts/armhf16k-verify-tree.py" --page-size "$PAGE_SIZE" "$OUT"

for soname in libGL.so.1 libGLX.so.0 libEGL.so.1 libGLdispatch.so.0; do
    if ! find "$OUT/usr/lib/arm-linux-gnueabihf" -maxdepth 1 \( -type f -o -type l \) -name "$soname" -print -quit | grep -q .; then
        echo "Private GLVND build is missing $soname" >&2
        exit 4
    fi
done

echo "PASS: private GLVND ARMHF build is 16K-compatible"
echo "GLVND staging root: $OUT"
