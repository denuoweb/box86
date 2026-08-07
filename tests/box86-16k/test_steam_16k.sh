#!/bin/sh
set -eu

BOX86_BIN=${BOX86_BIN:-box86-16k}
STEAM_CLIENT=${STEAM_CLIENT:-"$HOME/.local/share/Steam/ubuntu12_32/steam"}
TMP=${TMPDIR:-/tmp}/box86-steam16k.$$
TRACE="$TMP/trace-%pid.log"
OUT="$TMP/stdout.log"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if [ "$(getconf PAGESIZE)" -lt 16384 ]; then
    echo "SKIP: Steam 16K regression requires a >=16K host page size" >&2
    exit 77
fi
[ -x "$STEAM_CLIENT" ] || { echo "SKIP: 32-bit Steam client not found: $STEAM_CLIENT" >&2; exit 77; }
if ! command -v "$BOX86_BIN" >/dev/null 2>&1 && [ ! -x "$BOX86_BIN" ]; then
    echo "SKIP: Box86 binary not found: $BOX86_BIN" >&2
    exit 77
fi

set +e
BOX86_NORCFILES=1 \
BOX86_EMULATED_LIBS= \
BOX86_DYNAREC=0 \
BOX86_LOG=1 \
BOX86_TRACE=0x309e9f00-0x309ea000 \
BOX86_TRACE_FILE="$TRACE" \
STEAM_RUNTIME=1 \
STEAMOS=1 \
"$BOX86_BIN" "$STEAM_CLIENT" -srt-logger-opened >"$OUT" 2>&1
rc=$?
set -e

cat "$OUT"
if grep -H -E 'Illegal Opcode 0x309e9f8a|FF FF FF FF FF FF' "$TMP"/trace-*.log "$OUT" >/dev/null 2>&1; then
    grep -H -E 'Illegal Opcode|309e9f8a|FF FF FF FF FF FF' "$TMP"/trace-*.log "$OUT" >&2 || true
    echo "FAIL: Steam reproduced the pre-fix 0x309e9f8a/FF fault" >&2
    exit 1
fi

echo "PASS: Steam client did not reproduce 0x309e9f8a/FF (box86 rc=$rc)"
