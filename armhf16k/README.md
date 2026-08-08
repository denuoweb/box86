# ARMHF 16K native-library runtime

Box86 can now load 4K-aligned i386 guest ELF files on a 16K-page Raspberry Pi 5 kernel, but Box86 also wraps selected native ARMHF libraries. Those native libraries are loaded by the host dynamic loader, so an ARMHF DSO whose PT_LOAD layout is only compatible with 4K pages can still fail with:

```text
ELF load command address/offset not page-aligned
```

This directory contains the second half of the 16K effort: a reproducible Debian ARMHF package rebuilder and local APT repository for native libraries that are not 16K-loadable.

## Invariant

For each ARM ELF PT_LOAD segment, the runtime auditor requires:

```text
(p_vaddr - p_offset) % 16384 == 0
```

The rebuilder adds this linker policy to Debian package builds:

```text
-Wl,-z,max-page-size=0x4000
```

It then extracts every generated `.deb` and refuses to publish the source build if any shipped ARM ELF violates the 16K mapping invariant.

## Debian 13 / Pi 5 baseline

The first recursive GL/EGL audit found 15 incompatible ARMHF DSOs. They collapse to seven Debian source packages:

| Stage | Source package | Observed incompatible binary packages |
|---:|---|---|
| 10 | `zlib` | `zlib1g` |
| 20 | `libbsd` | `libbsd0` |
| 30 | `libxau` | `libxau6` |
| 40 | `libxcb` | `libxcb1`, `libxcb-randr0`, `libxcb-sync1`, `libxcb-present0`, `libxcb-xfixes0`, `libxcb-dri3-0`, `libxcb-shm0` |
| 50 | `elfutils` | `libelf1t64` |
| 60 | `llvm-toolchain-19` | `libllvm19` |
| 70 | `libglvnd` | `libgl1`, `libglx0`, `libegl1` |

The full observed SONAME list is in `baseline-debian13-pi5.tsv`. The source manifest is `manifest.tsv`.

Several important ARMHF components were already 16K-compatible and are intentionally not rebuilt, including glibc, `libX11.so.6`, `libGLdispatch.so.0`, Mesa's `libGLX_mesa.so.0` and `libEGL_mesa.so.0`, Gallium, DRM, and GBM.

## Bootstrap

The builder targets Debian 13 arm64 on Raspberry Pi 5:

```bash
bash scripts/armhf16k-bootstrap-debian13.sh
```

The bootstrap enables matching Debian source repositories when necessary, installs `sbuild` and QEMU linux-user support, and creates a reusable clean ARMHF build root under:

```text
~/.cache/sbuild/trixie-armhf.tar.gz
```

A 16K arm64 kernel can execute ARMHF in principle, but stock Debian ARMHF bootstrap binaries may themselves have 4K-only PT_LOAD layouts. That creates a bootstrap cycle: the ARMHF package set must be rebuilt for 16K before all of its own build tools can be executed natively. ARMHF16K breaks that cycle with a temporary QEMU ARM binfmt registration while the clean root and packages are being built.

The temporary handler is named `armhf16k-qemu-arm`. It uses Debian's QEMU ARM linux-user interpreter and is removed by traps after bootstrap/build. It is intentionally not left enabled, because the final runtime is supposed to execute the rebuilt ARMHF libraries directly on the 16K kernel rather than through QEMU.

Build dependencies are **not** installed into the normal host package database. Each source is built as ARMHF inside an ephemeral ARMHF sbuild environment, with QEMU used only as the execution bridge for stock 4K-oriented build tools. This avoids both host Multi-Arch development-package collisions and Debian cross-build dependency graphs that are `bd-uninstallable`.

The unshare backend requires unprivileged user namespaces. The bootstrap checks this before declaring the environment ready.

## Audit the installed ARMHF closure

```bash
python3 scripts/armhf16k-audit.py --bad-only
```

To make incompatibility a failing test:

```bash
python3 scripts/armhf16k-audit.py --bad-only --fail-on-bad
```

The default roots are GL, GLX, Mesa GLX, EGL, Mesa EGL, GLdispatch, and GBM. Dependencies are followed recursively through `DT_NEEDED` using ARMHF paths from `ldconfig`.

## Rebuild the full incompatible source set

```bash
bash scripts/armhf16k-build-all.sh
```

For each stage the rebuilder:

1. downloads the configured Debian source package on the host;
2. applies any source-specific ARMHF16K hook;
3. creates a local `+16k1` source revision with the 16K linker policy persisted in `debian/rules`;
4. enables the private QEMU ARM binfmt temporarily and invokes `sbuild --arch=armhf` in the clean unshare root;
5. exposes previously built packages from `armhf16k/repo/pool/` to sbuild through its transient extra-package archive;
6. removes the temporary QEMU handler;
7. validates every ARM ELF in every generated `.deb` before publishing it.

The QEMU step is build-time scaffolding only. A package is not accepted merely because it works under QEMU; it must pass the direct 16K PT_LOAD verifier before entering the local repository.

The source build is validated before its `.deb` files are copied into:

```text
armhf16k/repo/pool/
```

Useful controls:

```bash
ONLY_SOURCE=zlib bash scripts/armhf16k-build-all.sh
START_AT=libxcb bash scripts/armhf16k-build-all.sh
STOP_AFTER=elfutils bash scripts/armhf16k-build-all.sh
```

`llvm-toolchain-19` is intentionally late in the build because it is much larger than the other source packages.

## Create and enable the local repository

`armhf16k-build-all.sh` creates the repository index automatically after a complete run. It can also be regenerated directly:

```bash
bash scripts/armhf16k-make-repo.sh
bash scripts/armhf16k-enable-repo.sh
```

The repository is a flat local APT repository marked trusted because it is generated locally from Debian source packages. It does not replace or modify upstream repository configuration.

## Install the rebuilt runtime packages

```bash
bash scripts/armhf16k-install-targets.sh
```

The installer requests only the binary packages observed as incompatible. APT resolves same-source exact-version dependencies from the local repository when required. After installation, the recursive auditor runs again and fails if any GL/EGL closure library is still 16K-incompatible.

## Package updates

A later Debian security or point update can supersede a local `+16k` package. That is desirable for package correctness but may reintroduce 4K-only ELF layout. Re-run the audit after ARMHF library upgrades. If a new Debian version is incompatible, rebuild that source package again so the local version is based on the new Debian source.

## Scope

This runtime layer fixes host-side ARMHF ELF layout. It is distinct from the Box86 guest-side patches under `patches/16k/`:

1. Box86 guest ELF/mprotect support lets 4K-oriented i386 programs execute on a 16K host.
2. ARMHF16K rebuilds native libraries that Box86 wraps so the host dynamic loader can map them on the same 16K kernel.

Both layers are required for full native-wrapper workloads such as Steam on the Raspberry Pi 5 16K kernel.
