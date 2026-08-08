#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-}
HOST_ARCH=${HOST_ARCH:-armhf}
PAGE_SIZE=${PAGE_SIZE:-16384}
PAGE_HEX=$(printf '0x%x' "$PAGE_SIZE")
LOCAL_REVISION=${ARMHF16K_LOCAL_REVISION:-16k2}
WORK_ROOT=${ARMHF16K_WORK:-"$ROOT/armhf16k/work"}
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}
REPO=${ARMHF16K_REPO:-"$ROOT/armhf16k/repo"}
MANIFEST=${ARMHF16K_MANIFEST:-"$ROOT/armhf16k/manifest.tsv"}

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
CODENAME=${VERSION_CODENAME:-trixie}
PROOT_BASE=${ARMHF16K_PROOT_BASE:-"$HOME/.cache/armhf16k/${CODENAME}-${HOST_ARCH}-proot.tar.gz"}

if [[ -z "$SOURCE" ]]; then
    echo "usage: $0 <Debian source package>" >&2
    exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-get apt-cache dpkg dpkg-source dpkg-parsechangelog dch python3 readelf tar proot qemu-arm; do
    need "$x"
done

if [[ ! -r "$PROOT_BASE" ]]; then
    echo "Missing ARMHF PRoot base: $PROOT_BASE" >&2
    echo "Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

if ! apt-get --print-uris --only-source source "$SOURCE" >/dev/null 2>&1; then
    echo "APT cannot resolve source package '$SOURCE'. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

WORK="$WORK_ROOT/$SOURCE"
FETCH="$WORK/fetch"
SRC="$WORK/src"
GUEST="$WORK/rootfs"
rm -rf "$WORK"
mkdir -p "$FETCH" "$POOL" "$GUEST"

echo "Fetching Debian source: $SOURCE"
(
    cd "$FETCH"
    apt-get --download-only --only-source source "$SOURCE"
)

DSC=$(find "$FETCH" -maxdepth 1 -type f -name '*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
if [[ -z "$DSC" || ! -f "$DSC" ]]; then
    echo "No .dsc found after fetching $SOURCE" >&2
    exit 4
fi

dpkg-source -x "$DSC" "$SRC"

HOOK="$ROOT/armhf16k/hooks/$SOURCE.sh"
if [[ -f "$HOOK" ]]; then
    echo "Applying ARMHF16K source hook: $SOURCE"
    bash "$HOOK" "$SRC"
fi

export DEBFULLNAME=${DEBFULLNAME:-DenuoWeb ARMHF16K Builder}
export DEBEMAIL=${DEBEMAIL:-5424250+denuoweb@users.noreply.github.com}

# Base local versions on the current binary candidate when it is a binNMU
# (for example source -1 with binary -1+b1). Appending +16kN to that candidate
# makes the rebuilt package newer than the exact binary it replaces while still
# allowing a later Debian source revision to supersede it naturally.
SOURCE_VERSION=$(dpkg-parsechangelog -l"$SRC/debian/changelog" -S Version)
TARGET_BINARY=$(awk -F'\t' -v src="$SOURCE" '$2 == src {split($3,a,","); print a[1]; exit}' "$MANIFEST")
CANDIDATE=
if [[ -n "$TARGET_BINARY" ]]; then
    CANDIDATE=$(apt-cache policy "${TARGET_BINARY}:${HOST_ARCH}" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
fi
if [[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" && "$CANDIDATE" == "$SOURCE_VERSION"* ]]; then
    LOCAL_VERSION="${CANDIDATE}+${LOCAL_REVISION}"
else
    LOCAL_VERSION="${SOURCE_VERSION}+${LOCAL_REVISION}"
fi

(
    cd "$SRC"
    dch --newversion "$LOCAL_VERSION" --distribution unstable --force-distribution \
        "Rebuild ARMHF binaries for ${PAGE_SIZE}-byte host-page compatibility."
)
echo "ARMHF16K package version: $LOCAL_VERSION"

# Persist the linker policy in the source tree so every build system that uses
# Debian's dpkg-buildflags sees the 16K maximum-page-size requirement.
python3 - "$SRC/debian/rules" "$PAGE_HEX" <<'PY'
from pathlib import Path
import sys

rules = Path(sys.argv[1])
page_hex = sys.argv[2]
text = rules.read_text()
marker = "# ARMHF16K injected build policy"
if marker not in text:
    lines = text.splitlines(keepends=True)
    insert_at = 1 if lines and lines[0].startswith("#!") else 0
    block = (
        "# ARMHF16K injected build policy\n"
        f"export DEB_LDFLAGS_APPEND += -Wl,-z,max-page-size={page_hex}\n"
        "export DEB_BUILD_OPTIONS += nocheck\n"
    )
    lines.insert(insert_at, block)
    rules.write_text("".join(lines))
PY

# Each package gets a disposable ARMHF filesystem. PRoot owns binfmt behavior
# in userspace and inserts the host qemu-arm command for every guest exec, so
# stock 4K-linked ARMHF build tools never go through the 16K host ELF loader.
echo "Extracting disposable ARMHF PRoot environment"
tar --no-same-owner -xzf "$PROOT_BASE" -C "$GUEST"
mkdir -p "$GUEST/etc/apt/sources.list.d"
cat >"$GUEST/etc/apt/sources.list.d/armhf16k-local.list" <<'EOF'
deb [trusted=yes] file:/armhf16k-repo ./
EOF

proot_guest() {
    proot \
        -S "$GUEST" \
        -q qemu-arm \
        -b "$WORK:/work" \
        -b "$REPO:/armhf16k-repo" \
        -w /work \
        "$@"
}

echo "Building $SOURCE in isolated ARMHF PRoot/QEMU environment"
echo "guest=$HOST_ARCH page=$PAGE_SIZE"
echo "PRoot base: $PROOT_BASE"

proot_guest /bin/sh -lc \
    "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y --no-install-recommends build-dep '$SOURCE'"

proot_guest /bin/sh -lc \
    "cd /work/src && export DEB_BUILD_OPTIONS=nocheck && export DEB_BUILD_PROFILES=nocheck && dpkg-buildpackage -B -us -uc"

mapfile -t DEBS < <(find "$WORK" -maxdepth 1 -type f -name "*_${HOST_ARCH}.deb" ! -name '*-dbgsym_*' -print | sort)
if [[ ${#DEBS[@]} -eq 0 ]]; then
    echo "No ${HOST_ARCH} binary .deb files produced for $SOURCE" >&2
    exit 6
fi

# QEMU is only a bootstrap/build executor. Publication still requires every
# produced ARM ELF to be directly mappable by the real 16K host kernel.
python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size "$PAGE_SIZE" "${DEBS[@]}"

for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$POOL/"
    echo "Published: $POOL/$(basename "$deb")"
done

rm -rf "$GUEST"
