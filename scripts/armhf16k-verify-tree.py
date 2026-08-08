#!/usr/bin/env python3
"""Verify every ARM ELF32 object below a directory for large-host-page PT_LOAD congruence."""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

ELFCLASS32 = 1
EM_ARM = 40
PT_LOAD = 1


def audit(path: Path, page: int):
    try:
        with path.open("rb") as f:
            hdr = f.read(52)
    except OSError:
        return True, []
    if len(hdr) < 52 or hdr[:4] != b"\x7fELF" or hdr[4] != ELFCLASS32:
        return True, []
    endian = "<" if hdr[5] == 1 else ">"
    try:
        eh = struct.unpack(endian + "16sHHIIIIIHHHHHH", hdr)
    except struct.error:
        return False, []
    if eh[2] != EM_ARM:
        return True, []
    phoff, phentsize, phnum = eh[5], eh[9], eh[10]
    loads = []
    with path.open("rb") as f:
        f.seek(phoff)
        for _ in range(phnum):
            raw = f.read(phentsize)
            if len(raw) < 32:
                return False, loads
            p_type, off, va, _pa, _fs, _ms, _flags, align = struct.unpack(endian + "IIIIIIII", raw[:32])
            if p_type != PT_LOAD:
                continue
            ok = ((va - off) % page) == 0
            loads.append((off, va, align, ok))
    return all(seg[3] for seg in loads), loads


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--page-size", type=int, default=16384)
    args = ap.parse_args()
    root = Path(args.root)
    if not root.is_dir():
        print(f"missing tree: {root}")
        return 2
    failed = False
    found = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        ok, loads = audit(path, args.page_size)
        if not loads:
            continue
        found += 1
        rel = path.relative_to(root)
        if ok:
            print(f"OK   {rel}")
        else:
            failed = True
            print(f"BAD  {rel}")
            for off, va, align, seg_ok in loads:
                print(f"     LOAD off=0x{off:x} va=0x{va:x} align=0x{align:x} {'OK' if seg_ok else 'BAD'}")
    print(f"ARM ELF objects checked: {found}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
