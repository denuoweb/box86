#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(readlink -f "${ARMHF16K_REPO:-$ROOT/armhf16k/repo}")
SUDO=${SUDO:-sudo}
LIST=/etc/apt/sources.list.d/box86-armhf16k.list

[[ -f "$REPO/Packages.gz" ]] || {
    echo "$REPO/Packages.gz is missing. Run scripts/armhf16k-make-repo.sh first." >&2
    exit 2
}

printf 'deb [trusted=yes] file:%s ./\n' "$REPO" | $SUDO tee "$LIST" >/dev/null
$SUDO apt-get update

echo "Enabled local ARMHF16K repository in $LIST"
