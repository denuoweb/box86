# ARMHF 16K native-library runtime

Box86's guest-side loader can execute ordinary 4K-oriented i386 ELFs on a 16K-page Raspberry Pi 5 kernel, but Box86 also wraps selected native ARMHF libraries. Those libraries are mapped by the host dynamic loader and therefore need their own 16K-compatible PT_LOAD layout.

The runtime invariant is:

```text
(p_vaddr - p_offset) % 16384 == 0
```

ARMHF16K links rebuilt objects with:

```text
-Wl,-z,max-page-size=0x4000
```

## Pi 5 strategy

The original recursive Steam/GL audit found 15 incompatible ARMHF DSOs. Four low-level source packages were rebuilt and validated directly on the Pi:

- `zlib`
- `libbsd`
- `libxau`
- `libxcb` (all of its runtime extension libraries passed the verifier)

The generic Raspberry Pi Mesa package was already 16K-aligned, but its broad Gallium build depended on `libLLVM.so.19.1`, which in turn pulled `libelf.so.1` and other generic-driver dependencies. ARMHF16K does not rebuild that generic closure.

Instead, the graphics runtime is intentionally Pi 5-specific:

```text
validated zlib/libbsd/libXau/libxcb
                 |
                 v
Mesa: V3D Gallium + Broadcom V3DV only
LLVM disabled; no libLLVM/libelf closure
                 |
                 v
private 16K GLVND
                 |
                 v
/usr/lib/box86-16k/native16k
```

The private runtime does not overwrite `/usr/lib/arm-linux-gnueabihf`. `steam16k` uses it only for Box86 when the package is installed.

## Bootstrap

```bash
bash scripts/armhf16k-bootstrap-debian13.sh
```

The supported path uses native arm64 build tools and the Debian ARMHF cross compiler. PRoot, sbuild, QEMU binfmt and an ARMHF chroot are not part of the current build path.

## Stages

`armhf16k/manifest.tsv` defines:

```text
10  zlib
20  libbsd
30  libxau
40  libxcb
50  mesa-pi5-private
60  libglvnd-private
70  private-runtime
```

Build one stage with:

```bash
ONLY_SOURCE=mesa-pi5-private bash scripts/armhf16k-build-all.sh
```

or continue through the private graphics stages:

```bash
START_AT=mesa-pi5-private bash scripts/armhf16k-build-all.sh
```

The already validated low-level `.deb` files can remain in `armhf16k/repo/pool/`; the final runtime assembler extracts their libraries rather than installing them over Debian's system copies.

## Raspberry Pi Mesa

`scripts/armhf16k-build-mesa-pi5.sh`:

1. identifies the installed ARMHF Raspberry Pi Mesa candidate;
2. fetches the matching Pi-specific `rpt` source from the Raspberry Pi archive;
3. fetches Debian Trixie's `25.0.7-2+deb13u1` stable-security source and layers the CVE-2026-40393 backports onto the Pi tree;
4. cross-builds Mesa with `gallium-drivers=v3d`, `vulkan-drivers=broadcom`, and LLVM disabled;
5. installs into `armhf16k/private/mesa-root/`;
6. verifies every ARM ELF for 16K PT_LOAD congruence;
7. rejects the build if Gallium still has a `DT_NEEDED` entry for `libLLVM` or `libelf`.

It fails closed if the Pi source or the Debian security source cannot be obtained.

## Private GLVND

`scripts/armhf16k-build-libglvnd-private.sh` cross-builds GLVND with the same 16K linker policy and stages it under `armhf16k/private/glvnd-root/`.

## Assemble and install

Stage 70 creates:

```text
dist/box86-armhf16k-runtime_1.0+16k3_armhf.deb
```

The package installs under:

```text
/usr/lib/box86-16k/native16k/
```

and contains the private GLVND/Mesa closure plus the previously validated low-level libraries.

Install and validate it with:

```bash
bash scripts/armhf16k-install-targets.sh
```

Installation performs three checks before returning success:

1. every packaged ARM ELF satisfies the 16K mapping invariant;
2. the installed private tree satisfies the same invariant and contains no `libLLVM`/`libelf` dependency in the Pi graphics closure;
3. a freshly compiled 16K-linked ARMHF program directly `dlopen()`s GLVND, Mesa, Gallium/V3D, XCB and zlib through the real host kernel/glibc loader.

Only after that passes should `steam16k` be used as the next integration test.

## Box86 launcher integration

Box86 package `+16k7` makes `steam16k` detect `/usr/lib/box86-16k/native16k` and, only when present, configure:

- `LD_LIBRARY_PATH`
- `BOX86_LIBGL`
- `LIBGL_DRIVERS_PATH`
- `__EGL_VENDOR_LIBRARY_DIRS`
- private Vulkan ICD manifests

This leaves the normal Debian/Raspberry Pi graphics libraries unchanged for the rest of the system.
