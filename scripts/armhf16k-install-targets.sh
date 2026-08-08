#!/usr/bin/env bash
set -euo pipefail
trap 'rc=$?; echo "ERROR: ${BASH_SOURCE[0]}:${LINENO}: command failed (rc=$rc): $BASH_COMMAND" >&2; exit $rc' ERR

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUDO=${SUDO:-sudo}
DIST=${DISTDIR:-"$ROOT/dist"}

mapfile -t RUNTIME_DEBS < <(find "$DIST" -maxdepth 1 -type f -name 'box86-armhf16k-runtime_*_armhf.deb' -printf '%T@ %p\n' | sort -nr)
DEB=
if [[ ${#RUNTIME_DEBS[@]} -gt 0 ]]; then
    DEB=${RUNTIME_DEBS[0]#* }
fi
[[ -n "$DEB" && -f "$DEB" ]] || {
    echo "Private ARMHF16K runtime package not found in $DIST" >&2
    echo "Build stage private-runtime first." >&2
    exit 2
}

python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size 16384 "$DEB"
$SUDO apt-get install -y "$DEB"

PREFIX=/usr/lib/box86-16k/native16k
[[ -d "$PREFIX" ]] || { echo "Runtime package installed but $PREFIX is missing" >&2; exit 3; }
python3 "$ROOT/scripts/armhf16k-verify-tree.py" --page-size 16384 "$PREFIX"

# This is the decisive host-side check before Steam: compile a 16K-linked
# ARMHF dlopen harness and force the actual 16K kernel/glibc loader to resolve
# GLVND, Mesa, Gallium/V3D, XCB and zlib from the private closure.
bash "$ROOT/scripts/armhf16k-test-private-native.sh"

echo "Installed and host-validated private ARMHF16K runtime: $DEB"
echo "steam16k will prefer $PREFIX when the +16k7 launcher is installed."
