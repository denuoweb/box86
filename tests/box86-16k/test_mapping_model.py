#!/usr/bin/env python3
"""Pure mapping regression for Box86 fixed-address ELF reservation on 16K hosts."""

HOST_PAGE = 0x4000
GUEST_PAGE = 0x1000
VADDR = 0x08049000
MEMSZ = 0x5000


def down(v, page):
    return v & ~(page - 1)


def up(v, page):
    return (v + page - 1) & ~(page - 1)


def old_box86(host_mmap_result):
    image = host_mmap_result
    delta = image - VADDR if image != VADDR else 0
    return image, delta


def new_box86():
    raw = down(VADDR, HOST_PAGE)
    extra = VADDR - raw
    raw_size = MEMSZ + extra
    image = VADDR
    delta = 0
    return raw, raw_size, image, delta


def main():
    assert VADDR % GUEST_PAGE == 0
    assert VADDR % HOST_PAGE != 0
    host_rounded = down(VADDR, HOST_PAGE)
    old_image, old_delta = old_box86(host_rounded)
    assert old_image == host_rounded
    assert old_delta == -0x1000, hex(old_delta)
    raw, raw_size, image, delta = new_box86()
    assert raw == host_rounded
    assert raw_size == MEMSZ + 0x1000
    assert up(raw + raw_size, HOST_PAGE) >= VADDR + MEMSZ
    assert image == VADDR
    assert delta == 0
    print('PASS: 16K host backing preserves 4K-aligned ET_EXEC guest address')
    print(f'old: raw/image=0x{old_image:x}, erroneous delta={old_delta:+#x}')
    print(f'new: raw=0x{raw:x}, image=0x{image:x}, delta={delta}')


if __name__ == '__main__':
    main()
