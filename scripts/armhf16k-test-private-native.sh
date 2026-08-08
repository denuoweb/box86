#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX=${ARMHF16K_NATIVE_DIR:-/usr/lib/box86-16k/native16k}
WORK=${ARMHF16K_NATIVE_TEST_WORK:-"$ROOT/armhf16k/work/native-dlopen-test"}
CC=${CC:-arm-linux-gnueabihf-gcc}

[[ -d "$PREFIX" ]] || { echo "Private runtime not found: $PREFIX" >&2; exit 2; }
command -v "$CC" >/dev/null 2>&1 || { echo "Missing compiler: $CC" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK"
cat >"$WORK/dlopen16k.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    int failed = 0;
    for (int i = 1; i < argc; ++i) {
        dlerror();
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            fprintf(stderr, "FAIL %s: %s\n", argv[i], dlerror());
            failed = 1;
        } else {
            printf("OK   %s\n", argv[i]);
            dlclose(h);
        }
    }
    return failed;
}
C

"$CC" -O2 -Wl,-z,max-page-size=0x4000 -o "$WORK/dlopen16k" "$WORK/dlopen16k.c" -ldl
python3 "$ROOT/scripts/armhf16k-verify-tree.py" --page-size 16384 "$WORK"

libs=(
    "$PREFIX/libz.so.1"
    "$PREFIX/libXau.so.6"
    "$PREFIX/libxcb.so.1"
    "$PREFIX/libGLdispatch.so.0"
    "$PREFIX/libGLX_mesa.so.0"
    "$PREFIX/libEGL_mesa.so.0"
    "$PREFIX/libGLX.so.0"
    "$PREFIX/libEGL.so.1"
    "$PREFIX/libGL.so.1"
)

for gallium in "$PREFIX"/libgallium*.so*; do
    [[ -f "$gallium" ]] && libs+=("$gallium")
done
for dri in "$PREFIX"/dri/v3d_dri.so "$PREFIX"/dri/vc4_dri.so; do
    [[ -f "$dri" ]] && libs+=("$dri")
done

LD_LIBRARY_PATH="$PREFIX${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
LIBGL_DRIVERS_PATH="$PREFIX/dri" \
"$WORK/dlopen16k" "${libs[@]}"

echo "PASS: private ARMHF16K native closure dlopens directly on host page size $(getconf PAGESIZE)"
