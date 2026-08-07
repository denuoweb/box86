#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${ARMHF16K_MANIFEST:-"$ROOT/armhf16k/manifest.tsv"}
ONLY_SOURCE=${ONLY_SOURCE:-}
START_AT=${START_AT:-}
STOP_AFTER=${STOP_AFTER:-}
started=0

if [[ -z "$START_AT" ]]; then
    started=1
fi

while IFS=$'\t' read -r stage source binaries; do
    [[ -z "$stage" || "$stage" == \#* ]] && continue
    if [[ -n "$ONLY_SOURCE" && "$source" != "$ONLY_SOURCE" ]]; then
        continue
    fi
    if [[ $started -eq 0 ]]; then
        [[ "$source" == "$START_AT" ]] || continue
        started=1
    fi

    echo
    echo "============================================================"
    echo "ARMHF16K stage $stage: $source"
    echo "Observed bad binary packages: $binaries"
    echo "============================================================"
    "$ROOT/scripts/armhf16k-rebuild-source.sh" "$source"

    if [[ -n "$STOP_AFTER" && "$source" == "$STOP_AFTER" ]]; then
        break
    fi
done < "$MANIFEST"

"$ROOT/scripts/armhf16k-make-repo.sh"
