#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=${1:-}
HOST_ARCH=${HOST_ARCH:-armhf}
BUILD_ARCH=${BUILD_ARCH:-$(dpkg --print-architecture)}
PAGE_SIZE=${PAGE_SIZE:-16384}
PAGE_HEX=$(printf '0x%x' "$PAGE_SIZE")
WORK_ROOT=${ARMHF16K_WORK:-"$ROOT/armhf16k/work"}
POOL=${ARMHF16K_POOL:-"$ROOT/armhf16k/repo/pool"}

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
CODENAME=${VERSION_CODENAME:-trixie}
SBUILD_TARBALL=${ARMHF16K_SBUILD_TARBALL:-"$HOME/.cache/sbuild/${CODENAME}-${BUILD_ARCH}.tar.gz"}

if [[ -z "$SOURCE" ]]; then
    echo "usage: $0 <Debian source package>" >&2
    exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1" >&2; exit 2; }; }
for x in apt-get dpkg dpkg-source dpkg-parsechangelog dch python3 readelf sbuild; do
    need "$x"
done

if [[ ! -r "$SBUILD_TARBALL" ]]; then
    echo "Missing isolated sbuild base: $SBUILD_TARBALL" >&2
    echo "Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

# Resolve through apt-get's source command itself instead of inferring source
# availability from apt-cache. --print-uris performs resolution without a
# download and fails if the source package cannot be selected.
if ! apt-get --print-uris --only-source source "$SOURCE" >/dev/null 2>&1; then
    echo "APT cannot resolve source package '$SOURCE'. Run: bash scripts/armhf16k-bootstrap-debian13.sh" >&2
    exit 3
fi

WORK="$WORK_ROOT/$SOURCE"
FETCH="$WORK/fetch"
SRC="$WORK/src"
RESULT="$WORK/result"
rm -rf "$WORK"
mkdir -p "$FETCH" "$POOL" "$RESULT"

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

(
    cd "$SRC"
    dch --local +16k --distribution unstable --force-distribution \
        "Rebuild ARMHF binaries for ${PAGE_SIZE}-byte host-page compatibility."
)

# Persist the page-size policy in Debian packaging so it is active inside the
# clean sbuild environment instead of depending on host environment leakage.
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

# Recreate a source package containing our hook and linker-policy changes.
# For 3.0 (quilt) sources dpkg-source expects the original tarball next to the
# source tree; keep Debian's downloaded orig archives intact for that purpose.
find "$FETCH" -maxdepth 1 -type f -name '*.orig.tar.*' -exec cp -f {} "$WORK/" \;
(
    cd "$WORK"
    dpkg-source -b "$SRC"
)

LOCAL_DSC=$(find "$WORK" -maxdepth 1 -type f -name '*.dsc' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
if [[ -z "$LOCAL_DSC" || ! -f "$LOCAL_DSC" ]]; then
    echo "Failed to create local ARMHF16K source package for $SOURCE" >&2
    exit 5
fi

echo "Building $SOURCE in isolated sbuild environment"
echo "build=$BUILD_ARCH host=$HOST_ARCH page=$PAGE_SIZE"
echo "sbuild base: $SBUILD_TARBALL"

SBUILD_ARGS=(
    --chroot-mode=unshare
    --chroot="$SBUILD_TARBALL"
    --build="$BUILD_ARCH"
    --host="$HOST_ARCH"
    --dist="$CODENAME"
    --profiles=cross,nocheck
    --no-arch-all
    --no-run-lintian
    --no-run-piuparts
    --no-run-autopkgtest
    --build-dir="$RESULT"
    --add-depends-arch="crossbuild-essential-${HOST_ARCH}"
)

# Make earlier ARMHF16K builds available to dependency resolution without
# installing them on the host. sbuild copies these into its transient archive.
if compgen -G "$POOL/*.deb" >/dev/null; then
    SBUILD_ARGS+=(--extra-package="$POOL")
fi

sbuild "${SBUILD_ARGS[@]}" "$LOCAL_DSC"

mapfile -t DEBS < <(find "$RESULT" -maxdepth 1 -type f -name "*_${HOST_ARCH}.deb" ! -name '*-dbgsym_*' -print | sort)
if [[ ${#DEBS[@]} -eq 0 ]]; then
    echo "No ${HOST_ARCH} binary .deb files produced for $SOURCE" >&2
    exit 6
fi

# Do not publish a source build unless every ARM ELF shipped by its binary
# packages satisfies the 16K PT_LOAD congruence invariant.
python3 "$ROOT/scripts/armhf16k-verify-debs.py" --page-size "$PAGE_SIZE" "${DEBS[@]}"

for deb in "${DEBS[@]}"; do
    cp -f "$deb" "$POOL/"
    echo "Published: $POOL/$(basename "$deb")"
done
