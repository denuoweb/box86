#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUDO=${SUDO:-sudo}
DIST=${DISTDIR:-"$ROOT/dist"}

DEB=$(find "$DIST" -maxdepth 1 -type f -name 'box86-armhf16k-runtime_*_armhf.deb' -printf '%T@ %p\n' \
    | sort -nr | head -n1 | cut -d' ' -f2-)
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

echo "Installed private ARMHF16K runtime: $DEB"
echo "steam16k will prefer $PREFIX when the +16k7 launcher is installed."
