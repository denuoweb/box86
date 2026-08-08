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

while IFS=$'\t' read -r stage source targets; do
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
    echo "Runtime targets: $targets"
    echo "============================================================"

    case "$source" in
        zlib|libbsd|libxau|libxdmcp|libxcb|libxi|libasyncns)
            bash "$ROOT/scripts/armhf16k-rebuild-source.sh" "$source"
            ;;
        mesa-pi5-private)
            bash "$ROOT/scripts/armhf16k-build-mesa-pi5.sh"
            ;;
        libglvnd-private)
            bash "$ROOT/scripts/armhf16k-build-libglvnd-private.sh"
            ;;
        private-runtime)
            bash "$ROOT/scripts/armhf16k-assemble-private-runtime.sh"
            ;;
        *)
            echo "Unknown ARMHF16K stage: $source" >&2
            exit 2
            ;;
    esac

    if [[ -n "$STOP_AFTER" && "$source" == "$STOP_AFTER" ]]; then
        break
    fi
done < "$MANIFEST"

# Keep the package pool index useful for the low-level Debian rebuilds.
bash "$ROOT/scripts/armhf16k-make-repo.sh"
