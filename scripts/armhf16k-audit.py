#!/usr/bin/env python3
"""Audit ARMHF ELF PT_LOAD mappings for compatibility with a 16 KiB host page."""

from __future__ import annotations

import argparse
import json
import os
import re
import struct
import subprocess
from dataclasses import asdict, dataclass
from typing import Iterable

DEFAULT_PAGE_SIZE = 16384
DEFAULT_ROOTS = [
    "libGL.so.1",
    "libGLX.so.0",
    "libGLdispatch.so.0",
    "libGLX_mesa.so.0",
    "libEGL.so.1",
    "libEGL_mesa.so.0",
    "libgbm.so.1",
]
DEFAULT_ARMHF_DIRS = [
    "/usr/lib/arm-linux-gnueabihf",
    "/lib/arm-linux-gnueabihf",
]

ELFCLASS32 = 1
ELFDATA2LSB = 1
ELFDATA2MSB = 2
EM_ARM = 40
PT_LOAD = 1


@dataclass
class LoadSegment:
    offset: int
    vaddr: int
    align: int
    compatible: bool


@dataclass
class AuditRecord:
    soname: str
    path: str | None
    package: str | None
    elf32_arm: bool | None
    compatible: bool | None
    loads: list[LoadSegment]
    needed: list[str]
    error: str | None = None


def run_text(argv: list[str], *, check: bool = True) -> str:
    proc = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode:
        raise RuntimeError(f"{' '.join(argv)} failed: {proc.stderr.strip()}")
    return proc.stdout


def armhf_ldconfig() -> dict[str, list[str]]:
    out = run_text(["ldconfig", "-p"])
    result: dict[str, list[str]] = {}
    for line in out.splitlines():
        if "=>" not in line:
            continue
        left, path = line.split("=>", 1)
        soname = left.strip().split()[0]
        path = path.strip()
        if "arm-linux-gnueabihf" not in path:
            continue
        result.setdefault(soname, []).append(path)
    return result


def file_index(roots: Iterable[str]) -> dict[str, list[str]]:
    """Index SONAME-like files recursively below one or more library roots."""
    result: dict[str, list[str]] = {}
    seen_real_dirs: set[str] = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        real_root = os.path.realpath(root)
        if real_root in seen_real_dirs:
            continue
        seen_real_dirs.add(real_root)
        for directory, _subdirs, files in os.walk(root):
            for name in files:
                if ".so" not in name:
                    continue
                result.setdefault(name, []).append(os.path.join(directory, name))
    return result


def resolve_soname(
    soname: str,
    cache: dict[str, list[str]],
    system_index: dict[str, list[str]],
    overlays: list[str],
    overlay_index: dict[str, list[str]],
) -> str | None:
    """Resolve like LD_LIBRARY_PATH: private overlays first, then system ARMHF."""
    for root in overlays:
        path = os.path.join(root, soname)
        if os.path.exists(path):
            return path
    for path in overlay_index.get(soname, []):
        if os.path.exists(path):
            return path
    for path in cache.get(soname, []):
        if os.path.exists(path):
            return path
    for directory in DEFAULT_ARMHF_DIRS:
        path = os.path.join(directory, soname)
        if os.path.exists(path):
            return path
    for path in system_index.get(soname, []):
        if os.path.exists(path):
            return path
    return None


def package_for(path: str) -> str | None:
    proc = subprocess.run(
        ["dpkg-query", "-S", os.path.realpath(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode:
        return None
    line = proc.stdout.strip().splitlines()[0]
    return line.rsplit(": ", 1)[0] if ": " in line else line


def needed_for(path: str) -> list[str]:
    proc = subprocess.run(
        ["readelf", "-dW", path],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if proc.returncode:
        return []
    return re.findall(r"Shared library: \[(.*?)\]", proc.stdout)


def audit_elf(path: str, page_size: int) -> tuple[bool | None, list[LoadSegment], bool | None, str | None]:
    """Return (is_elf32_arm, loads, compatible, error)."""
    real = os.path.realpath(path)
    try:
        with open(real, "rb") as f:
            hdr = f.read(52)
    except OSError as exc:
        return None, [], None, str(exc)

    if len(hdr) < 52 or hdr[:4] != b"\x7fELF":
        return False, [], None, "not ELF"
    if hdr[4] != ELFCLASS32:
        return False, [], None, "not ELF32"
    if hdr[5] == ELFDATA2LSB:
        endian = "<"
    elif hdr[5] == ELFDATA2MSB:
        endian = ">"
    else:
        return False, [], None, "unknown ELF byte order"

    try:
        eh = struct.unpack(endian + "16sHHIIIIIHHHHHH", hdr)
    except struct.error as exc:
        return None, [], None, str(exc)

    machine = eh[2]
    if machine != EM_ARM:
        return False, [], None, f"ELF32 machine={machine}, not EM_ARM"

    phoff, phentsize, phnum = eh[5], eh[9], eh[10]
    loads: list[LoadSegment] = []
    try:
        with open(real, "rb") as f:
            f.seek(phoff)
            for _ in range(phnum):
                raw = f.read(phentsize)
                if len(raw) < 32:
                    return True, loads, None, "truncated program header"
                p_type, off, vaddr, _paddr, _filesz, _memsz, _flags, align = struct.unpack(
                    endian + "IIIIIIII", raw[:32]
                )
                if p_type != PT_LOAD:
                    continue
                ok = ((vaddr - off) % page_size) == 0
                loads.append(LoadSegment(off, vaddr, align, ok))
    except OSError as exc:
        return True, loads, None, str(exc)

    compatible = all(seg.compatible for seg in loads) if loads else True
    return True, loads, compatible, None


def record_for(soname: str, path: str | None, page_size: int) -> AuditRecord:
    if path is None:
        return AuditRecord(soname, None, None, None, None, [], [], "no ARMHF loader path found")
    real = os.path.realpath(path)
    is_arm, loads, compatible, error = audit_elf(real, page_size)
    return AuditRecord(
        soname=soname,
        path=real,
        package=package_for(real),
        elf32_arm=is_arm,
        compatible=compatible,
        loads=loads,
        needed=needed_for(real) if is_arm else [],
        error=error,
    )


def walk_closure(
    roots: Iterable[str], page_size: int, overlays: Iterable[str] = ()
) -> list[AuditRecord]:
    cache = armhf_ldconfig()
    system_index = file_index(DEFAULT_ARMHF_DIRS)
    overlay_roots = [os.path.abspath(p) for p in overlays if os.path.isdir(p)]
    overlay_index = file_index(overlay_roots)
    seen: set[str] = set()
    ordered: list[AuditRecord] = []

    def visit(soname: str) -> None:
        if soname in seen:
            return
        seen.add(soname)
        rec = record_for(
            soname,
            resolve_soname(soname, cache, system_index, overlay_roots, overlay_index),
            page_size,
        )
        ordered.append(rec)
        for dep in rec.needed:
            visit(dep)

    for root in roots:
        visit(root)
    return ordered


def print_human(records: list[AuditRecord], *, bad_only: bool) -> None:
    for rec in records:
        # "bad" includes incompatible, missing, and unresolved/unknown entries.
        if bad_only and rec.compatible is True:
            continue
        if rec.path is None:
            status = "MISSING"
        elif rec.compatible is True:
            status = "16K-OK"
        elif rec.compatible is False:
            status = "16K-BAD"
        else:
            status = "UNKNOWN"
        print(f"{rec.soname}: {status}")
        if rec.path:
            print(f"  {rec.path}")
        if rec.package:
            print(f"  package: {rec.package}")
        if rec.error and rec.error not in {"not ELF", "not ELF32"}:
            print(f"  error: {rec.error}")
        if rec.compatible is False:
            for seg in rec.loads:
                print(
                    f"  LOAD off=0x{seg.offset:x} va=0x{seg.vaddr:x} "
                    f"align=0x{seg.align:x} {'OK' if seg.compatible else 'BAD'}"
                )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="*", help="ARMHF SONAME roots; defaults to the GL/EGL closure")
    parser.add_argument("--page-size", type=int, default=DEFAULT_PAGE_SIZE)
    parser.add_argument("--bad-only", action="store_true")
    parser.add_argument("--overlay", action="append", default=[], help="library root searched before system ARMHF paths; repeatable")
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--fail-on-bad", action="store_true")
    args = parser.parse_args()

    roots = args.roots or DEFAULT_ROOTS
    records = walk_closure(roots, args.page_size, args.overlay)

    if args.as_json:
        print(json.dumps([asdict(r) for r in records], indent=2))
    else:
        print_human(records, bad_only=args.bad_only)
        bad = [r for r in records if r.compatible is False]
        missing = [r for r in records if r.path is None]
        print(f"\nsummary: {len(records)} libraries, {len(bad)} incompatible, {len(missing)} missing")

    if args.fail_on_bad and any(r.compatible is False or r.path is None for r in records):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
