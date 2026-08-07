#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=${ARMHF16K_REPO:-"$ROOT/armhf16k/repo"}
POOL="$REPO/pool"

command -v dpkg-scanpackages >/dev/null 2>&1 || {
    echo "dpkg-scanpackages is required (package: dpkg-dev)." >&2
    exit 2
}

mkdir -p "$POOL"
if ! find "$POOL" -maxdepth 1 -type f -name '*.deb' -print -quit | grep -q .; then
    echo "No .deb files found in $POOL" >&2
    exit 3
fi

(
    cd "$REPO"
    dpkg-scanpackages --multiversion pool /dev/null > Packages
    gzip -9fk Packages
)

echo "Flat APT repository ready: $REPO"
echo "Packages: $(grep -c '^Package:' "$REPO/Packages")"
