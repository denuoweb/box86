#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BOX86_BIN=${BOX86_BIN:-box86-16k}
TMP=${TMPDIR:-/tmp}/box86-16k-regression.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

python3 "$ROOT/tests/box86-16k/make_elf32_16k_fixture.py" "$TMP/elf32-16k-overlap" >/dev/null
pagesize=$(getconf PAGESIZE)
echo "host page size: $pagesize"

if [ "$pagesize" -lt 16384 ]; then
    echo "NOTE: structural test is valid, but this host cannot reproduce the 16K kernel path." >&2
fi
if ! command -v "$BOX86_BIN" >/dev/null 2>&1 && [ ! -x "$BOX86_BIN" ]; then
    echo "box86 binary not found: $BOX86_BIN" >&2
    exit 77
fi

set +e
out=$(BOX86_NORCFILES=1 BOX86_DYNAREC=0 BOX86_LOG=1 "$BOX86_BIN" "$TMP/elf32-16k-overlap" 2>&1)
rc=$?
set -e
printf '%s\n' "$out"

if printf '%s\n' "$out" | grep -Eq 'Illegal Opcode|Cannot create memory map|ELF load command address/offset not page-aligned'; then
    echo "FAIL: non-4K ELF mapping regression reproduced" >&2
    exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'BOX86_16K_ELF_OK'; then
    echo "FAIL: fixture did not execute successfully (rc=$rc)" >&2
    exit 1
fi

echo "PASS: 4K-aligned ELF32 PT_LOAD segments execute on host page size $pagesize"
