#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}
MESA_ROOT=${ARMHF16K_MESA_ROOT:-"$ROOT/armhf16k/private/mesa-root"}
GLVND_ROOT=${ARMHF16K_GLVND_ROOT:-"$ROOT/armhf16k/private/glvnd-root"}
WORK=${ARMHF16K_RUNTIME_WORK:-"$ROOT/armhf16k/work/private-runtime"}
DIST=${DISTDIR:-"$ROOT/dist"}
VERSION=${ARMHF16K_RUNTIME_VERSION:-1.0+16k3}
PREFIX=/usr/lib/box86-16k/native16k
PKGROOT="$WORK/pkg"
NATIVE="$PKGROOT$PREFIX"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in dpkg-deb python3 readelf; do need "$x"; done
[[ -d "$MESA_ROOT/usr/lib/arm-linux-gnueabihf" ]] || { echo "Missing Mesa staging root. Build mesa-pi5-private first." >&2; exit 3; }
[[ -d "$GLVND_ROOT/usr/lib/arm-linux-gnueabihf" ]] || { echo "Missing GLVND staging root. Build libglvnd-private first." >&2; exit 3; }

rm -rf "$WORK"
mkdir -p "$NATIVE" "$DIST" "$PKGROOT/DEBIAN"

copy_lib_tree() {
    src=$1
    [ -d "$src" ] || return 0
    cp -a "$src"/. "$NATIVE"/
}

# Pull the previously validated low-level libraries out of their .debs rather
# than replacing Debian's system copies. Include all runtime libxcb packages
# produced by the source build, plus zlib/libbsd/libXau.
TMP="$WORK/extract"
mkdir -p "$TMP"
found_zlib=0
found_bsd=0
found_xau=0
found_xcb=0
for deb in "$POOL"/*.deb; do
    [ -f "$deb" ] || continue
    pkg=$(dpkg-deb -f "$deb" Package)
    case "$pkg" in
        zlib1g) found_zlib=1 ;;
        libbsd0) found_bsd=1 ;;
        libxau6) found_xau=1 ;;
        libxcb*-dev|*-dbgsym) continue ;;
        libxcb*) found_xcb=1 ;;
        *) continue ;;
    esac
    dir="$TMP/$pkg"
    rm -rf "$dir"
    mkdir -p "$dir"
    dpkg-deb -x "$deb" "$dir"
    copy_lib_tree "$dir/usr/lib/arm-linux-gnueabihf"
done

[[ $found_zlib -eq 1 && $found_bsd -eq 1 && $found_xau -eq 1 && $found_xcb -eq 1 ]] || {
    echo "Low-level package pool is incomplete (zlib=$found_zlib bsd=$found_bsd xau=$found_xau xcb=$found_xcb)." >&2
    echo "Build stages zlib, libbsd, libxau and libxcb first." >&2
    exit 4
}

# Overlay Pi5-specific Mesa, then GLVND. GLVND owns the public libGL/libGLX/
# libEGL entry points; Mesa provides the vendor and hardware-driver libraries.
copy_lib_tree "$MESA_ROOT/usr/lib/arm-linux-gnueabihf"
copy_lib_tree "$GLVND_ROOT/usr/lib/arm-linux-gnueabihf"

if [[ -d "$MESA_ROOT/usr/share/glvnd/egl_vendor.d" ]]; then
    mkdir -p "$NATIVE/egl_vendor.d"
    cp -a "$MESA_ROOT/usr/share/glvnd/egl_vendor.d"/. "$NATIVE/egl_vendor.d"/
fi
if [[ -d "$MESA_ROOT/usr/share/vulkan/icd.d" ]]; then
    mkdir -p "$NATIVE/vulkan/icd.d"
    cp -a "$MESA_ROOT/usr/share/vulkan/icd.d"/. "$NATIVE/vulkan/icd.d"/
    find "$NATIVE/vulkan/icd.d" -type f -name '*.json' -exec \
        sed -i "s#/usr/lib/arm-linux-gnueabihf/#${PREFIX}/#g" {} +
fi

cat >"$NATIVE/runtime.env" <<EOF
ARMHF16K_NATIVE_DIR=${PREFIX}
ARMHF16K_DRI_DIR=${PREFIX}/dri
ARMHF16K_EGL_VENDOR_DIR=${PREFIX}/egl_vendor.d
ARMHF16K_VULKAN_ICD_DIR=${PREFIX}/vulkan/icd.d
EOF

python3 "$ROOT/scripts/armhf16k-verify-tree.py" --page-size 16384 "$NATIVE"

# The point of the Pi5-specific Mesa build is to delete the generic LLVM/libelf
# closure, not merely hide it. Reject either dependency anywhere in the private
# runtime before packaging.
while IFS= read -r -d '' file; do
    needed=$(readelf -dW "$file" 2>/dev/null || true)
    if printf '%s\n' "$needed" | grep -Eq 'Shared library: \[(libLLVM[^]]*|libelf\.so[^]]*)\]'; then
        echo "Forbidden generic graphics dependency in private runtime: $file" >&2
        printf '%s\n' "$needed" | grep NEEDED >&2 || true
        exit 5
    fi
done < <(find "$NATIVE" -type f -print0)

# Sanity-check the hard dependencies that originally stopped steamui.so.
for soname in libGL.so.1 libGLX.so.0 libEGL.so.1 libxcb.so.1 libXau.so.6 libz.so.1; do
    find "$NATIVE" -maxdepth 1 \( -type f -o -type l \) -name "$soname" -print -quit | grep -q . || {
        echo "Private runtime is missing $soname" >&2
        exit 5
    }
done
find "$NATIVE/dri" -maxdepth 1 -type f \( -name 'v3d_dri.so' -o -name 'vc4_dri.so' \) -print -quit 2>/dev/null | grep -q . || {
    echo "Private Mesa runtime has no Pi V3D/VC4 DRI driver" >&2
    exit 5
}

cat >"$PKGROOT/DEBIAN/control" <<EOF
Package: box86-armhf16k-runtime
Version: ${VERSION}
Architecture: armhf
Maintainer: DenuoWeb <5424250+denuoweb@users.noreply.github.com>
Depends: libc6 (>= 2.38), libdrm2, libx11-6, libxext6, libx11-xcb1, libwayland-client0, libwayland-server0, libexpat1, libzstd1, libgcc-s1, libstdc++6
Description: Private 16K-compatible ARMHF native runtime for Box86
 Provides Box86 with a private ARMHF GL/X11 dependency closure for 16 KiB-page
 hosts. Includes Pi5 V3D/V3DV Mesa, GLVND, and rebuilt low-level libraries.
EOF

DEB="$DIST/box86-armhf16k-runtime_${VERSION}_armhf.deb"
dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB"
python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size 16384 "$DEB"
echo "Built: $DEB"
