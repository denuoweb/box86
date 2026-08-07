#!/usr/bin/env python3
"""Generate a tiny static i386 ELF whose 4K PT_LOADs share a 16K host page."""
from __future__ import annotations

import argparse
import os
import struct
from pathlib import Path

ELF_BASE = 0x08049000
TEXT_VADDR = ELF_BASE + 0x1000
TEXT_OFFSET = 0x1000
PAGE_4K = 0x1000


def make_fixture(path: Path) -> None:
    msg = b"BOX86_16K_ELF_OK\n"
    code_len = 31
    msg_addr = TEXT_VADDR + code_len
    code = b"".join([
        b"\xB8\x04\x00\x00\x00",
        b"\xBB\x01\x00\x00\x00",
        b"\xB9" + struct.pack("<I", msg_addr),
        b"\xBA" + struct.pack("<I", len(msg)),
        b"\xCD\x80",
        b"\xB8\x01\x00\x00\x00",
        b"\x31\xDB",
        b"\xCD\x80",
    ])
    assert len(code) == code_len
    text = code + msg
    ident = b"\x7fELF" + bytes([1, 1, 1, 0, 0]) + bytes(7)
    ehdr = struct.pack(
        "<16sHHIIIIIHHHHHH", ident, 2, 3, 1, TEXT_VADDR, 52, 0, 0,
        52, 32, 2, 0, 0, 0,
    )
    header_filesz = 52 + 2 * 32
    ph0 = struct.pack(
        "<IIIIIIII", 1, 0, ELF_BASE, ELF_BASE, header_filesz,
        header_filesz, 4, PAGE_4K,
    )
    ph1 = struct.pack(
        "<IIIIIIII", 1, TEXT_OFFSET, TEXT_VADDR, TEXT_VADDR,
        len(text), len(text), 5, PAGE_4K,
    )
    blob = bytearray(ehdr + ph0 + ph1)
    blob.extend(b"\0" * (TEXT_OFFSET - len(blob)))
    blob.extend(text)
    path.write_bytes(blob)
    os.chmod(path, 0o755)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("output", nargs="?", default="elf32-16k-overlap")
    args = ap.parse_args()
    out = Path(args.output)
    make_fixture(out)
    print(out)


if __name__ == "__main__":
    main()
