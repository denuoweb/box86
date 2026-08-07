#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${ARMHF16K_MANIFEST:-"$ROOT/armhf16k/manifest.tsv"}
HOST_ARCH=${HOST_ARCH:-armhf}
SUDO=${SUDO:-sudo}

mapfile -t PACKAGES < <(
    awk -F'\t' '!/^#/ && NF >= 3 {print $3}' "$MANIFEST" \
      | tr ',' '\n' \
      | sed '/^[[:space:]]*$/d' \
      | sort -u
)

if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    echo "No target binary packages found in $MANIFEST" >&2
    exit 2
fi

ARGS=()
for pkg in "${PACKAGES[@]}"; do
    ARGS+=("${pkg}:${HOST_ARCH}")
done

$SUDO apt-get install -y "${ARGS[@]}"

echo
python3 "$ROOT/scripts/armhf16k-audit.py" --bad-only --fail-on-bad
