#!/usr/bin/env python3
"""Verify that ARM ELF files shipped by .deb packages can be mapped on 16 KiB pages."""

from __future__ import annotations

import argparse
import struct
import subprocess
import tempfile
from pathlib import Path

PAGE = 16384
ELFCLASS32 = 1
EM_ARM = 40
PT_LOAD = 1


def audit(path: Path, page: int) -> tuple[bool, list[tuple[int, int, int, bool]]]:
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
    return all(x[3] for x in loads), loads


def field(deb: Path, name: str) -> str:
    return subprocess.check_output(["dpkg-deb", "-f", str(deb), name], text=True).strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("debs", nargs="+")
    ap.add_argument("--page-size", type=int, default=PAGE)
    args = ap.parse_args()

    failed = False
    for raw in args.debs:
        deb = Path(raw)
        if not deb.is_file():
            print(f"SKIP missing {deb}")
            continue
        arch = field(deb, "Architecture")
        pkg = field(deb, "Package")
        version = field(deb, "Version")
        print(f"=== {pkg}:{arch} {version} ===")
        with tempfile.TemporaryDirectory(prefix="armhf16k-deb-") as td:
            root = Path(td)
            subprocess.check_call(["dpkg-deb", "-x", str(deb), str(root)])
            for path in sorted(root.rglob("*")):
                if not path.is_file() or path.is_symlink():
                    continue
                ok, loads = audit(path, args.page_size)
                if not loads:
                    continue
                rel = "/" + str(path.relative_to(root))
                if ok:
                    print(f"OK   {rel}")
                else:
                    failed = True
                    print(f"BAD  {rel}")
                    for off, va, align, seg_ok in loads:
                        print(
                            f"     LOAD off=0x{off:x} va=0x{va:x} "
                            f"align=0x{align:x} {'OK' if seg_ok else 'BAD'}"
                        )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
