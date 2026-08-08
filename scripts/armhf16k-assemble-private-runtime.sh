#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}
MESA_ROOT=${ARMHF16K_MESA_ROOT:-"$ROOT/armhf16k/private/mesa-root"}
GLVND_ROOT=${ARMHF16K_GLVND_ROOT:-"$ROOT/armhf16k/private/glvnd-root"}
WORK=${ARMHF16K_RUNTIME_WORK:-"$ROOT/armhf16k/work/private-runtime"}
DIST=${DISTDIR:-"$ROOT/dist"}
VERSION=${ARMHF16K_RUNTIME_VERSION:-1.0+16k5}
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

# Pull the validated low-level libraries out of their .debs rather than
# replacing Debian's system copies. Include all runtime libxcb packages plus
# the native dependencies encountered by Steam/Box86 on the 16K host.
TMP="$WORK/extract"
mkdir -p "$TMP"
found_zlib=0
found_bsd=0
found_xau=0
found_xdmcp=0
found_xcb=0
found_xi=0
found_asyncns=0
for deb in "$POOL"/*.deb; do
    [ -f "$deb" ] || continue
    pkg=$(dpkg-deb -f "$deb" Package)
    case "$pkg" in
        zlib1g) found_zlib=1 ;;
        libbsd0) found_bsd=1 ;;
        libxau6) found_xau=1 ;;
        libxdmcp6) found_xdmcp=1 ;;
        libxi6) found_xi=1 ;;
        libasyncns0) found_asyncns=1 ;;
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

[[ $found_zlib -eq 1 && $found_bsd -eq 1 && $found_xau -eq 1 && $found_xdmcp -eq 1 && $found_xcb -eq 1 && $found_xi -eq 1 && $found_asyncns -eq 1 ]] || {
    echo "Low-level package pool is incomplete (zlib=$found_zlib bsd=$found_bsd xau=$found_xau xdmcp=$found_xdmcp xcb=$found_xcb xi=$found_xi asyncns=$found_asyncns)." >&2
    echo "Build stages zlib, libbsd, libxau, libxdmcp, libxcb, libxi and libasyncns first." >&2
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

# Sanity-check the hard dependencies that have stopped Steam/steamui.so during
# real 16K-host validation.
for soname in libGL.so.1 libGLX.so.0 libEGL.so.1 libxcb.so.1 libXau.so.6 libXdmcp.so.6 libXi.so.6 libasyncns.so.0 libz.so.1; do
    find "$NATIVE" -maxdepth 1 \( -type f -o -type l \) -name "$soname" -print -quit | grep -q . || {
        echo "Private runtime is missing $soname" >&2
        exit 5
    }
done

# Mesa's dril target creates these as symlinks to libdril_dri.so. Steam's X/GLX
# path on Pi5 has been observed requesting vc4_dri.so, while V3D is the render
# driver, so require both aliases and ensure they resolve inside this runtime.
for driver in "$NATIVE/dri/v3d_dri.so" "$NATIVE/dri/vc4_dri.so"; do
    [[ -e "$driver" || -L "$driver" ]] || {
        echo "Private Mesa runtime is missing Pi DRI driver: $driver" >&2
        exit 5
    }
    target=$(readlink -f -- "$driver" 2>/dev/null || true)
    [[ -n "$target" && -f "$target" ]] || {
        echo "Pi DRI driver is a broken link: $driver" >&2
        exit 5
    }
    case "$target" in
        "$NATIVE"/*) ;;
        *)
            echo "Pi DRI driver resolves outside private runtime: $driver -> $target" >&2
            exit 5
            ;;
    esac
    echo "Verified Pi DRI driver: $driver -> $target"
done

cat >"$PKGROOT/DEBIAN/control" <<EOF
Package: box86-armhf16k-runtime
Version: ${VERSION}
Architecture: armhf
Maintainer: DenuoWeb <5424250+denuoweb@users.noreply.github.com>
Depends: libc6 (>= 2.38), libdrm2, libx11-6, libxext6, libx11-xcb1, libwayland-client0, libwayland-server0, libexpat1, libzstd1, libgcc-s1, libstdc++6
Description: Private 16K-compatible ARMHF native runtime for Box86
 Provides Box86 with a private ARMHF GL/X11 dependency closure for 16 KiB-page
 hosts. Includes Pi V3D/VC4/V3DV Mesa, GLVND, and rebuilt low-level libraries.
EOF

DEB="$DIST/box86-armhf16k-runtime_${VERSION}_armhf.deb"
dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB"
python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size 16384 "$DEB"
echo "Built: $DEB"
