#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
COMMIT=$(cat "$ROOT/packaging/box86-16k/UPSTREAM_COMMIT")
VERSION=$(cat "$ROOT/packaging/box86-16k/VERSION")
WORK=${WORKDIR:-"$ROOT/.build-box86-16k"}
SRC="$WORK/box86-$COMMIT"
DIST=${DISTDIR:-"$ROOT/dist"}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing build tool: $1" >&2; exit 2; }; }
for x in git cmake make python3 dpkg-buildpackage arm-linux-gnueabihf-gcc readelf; do need "$x"; done

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"

if [ -n "${BOX86_SOURCE:-}" ]; then
    echo "Cloning local Box86 source: $BOX86_SOURCE"
    git clone --no-hardlinks "$BOX86_SOURCE" "$SRC"
elif [ -d "$ROOT/.git" ]; then
    echo "Cloning this Box86 fork"
    git clone --no-hardlinks "$ROOT" "$SRC"
else
    echo "Cloning upstream Box86"
    git clone https://github.com/ptitSeb/box86.git "$SRC"
fi

git -C "$SRC" checkout --detach "$COMMIT"
git -C "$SRC" reset --hard "$COMMIT"
git -C "$SRC" clean -fdx

for p in "$ROOT"/patches/16k/*.patch; do
    echo "Applying $(basename "$p")"
    git -C "$SRC" apply --check "$p"
    git -C "$SRC" apply "$p"
done

rm -rf "$SRC/debian"
cp -a "$ROOT/packaging/box86-16k/debian" "$SRC/debian"
mkdir -p "$SRC/tests/box86-16k"
cp "$ROOT/tests/box86-16k/make_elf32_16k_fixture.py" "$SRC/tests/box86-16k/"
cp "$ROOT/tests/box86-16k/test_16k_elfloader.sh" "$SRC/tests/box86-16k/"
cp "$ROOT/tests/box86-16k/test_steam_16k.sh" "$SRC/tests/box86-16k/"
cp "$ROOT/tests/box86-16k/test_mapping_model.py" "$SRC/tests/box86-16k/"

sed -i "1s/([^)]*)/($VERSION)/" "$SRC/debian/changelog"

(
    cd "$SRC"
    dpkg-buildpackage -b -us -uc -aarmhf
)

found=0
for deb in "$WORK"/box86-16k_*_armhf.deb; do
    [ -f "$deb" ] || continue
    cp "$deb" "$DIST/"
    echo "Built: $DIST/$(basename "$deb")"
    found=1
done
[ "$found" -eq 1 ] || { echo "Build finished but armhf .deb was not found" >&2; exit 1; }
