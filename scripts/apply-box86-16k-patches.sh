#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${1:-.}
COMMIT=$(cat "$ROOT/packaging/box86-16k/UPSTREAM_COMMIT")

[ -d "$SRC/.git" ] || { echo "Not a git checkout: $SRC" >&2; exit 2; }
actual=$(git -C "$SRC" rev-parse HEAD)
if [ "$actual" != "$COMMIT" ]; then
    echo "Expected Box86 commit $COMMIT, got $actual" >&2
    echo "Checkout the pinned commit or use scripts/build-box86-16k-deb.sh." >&2
    exit 2
fi
for p in "$ROOT"/patches/16k/*.patch; do
    echo "Applying $(basename "$p")"
    git -C "$SRC" apply --check "$p"
    git -C "$SRC" apply "$p"
done
