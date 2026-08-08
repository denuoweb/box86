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

A 16K arm64 kernel can execute AArch32 instructions, but stock Debian ARMHF bootstrap binaries can still contain 4K-only PT_LOAD layouts. That creates a bootstrap cycle: the ARMHF package set must be rebuilt for 16K before all of its own tools can be loaded directly by the host kernel.

ARMHF16K breaks that cycle entirely in userspace:

1. `debootstrap --foreign --arch=armhf` downloads and extracts the base ARMHF filesystem without executing ARMHF programs;
2. PRoot runs debootstrap's second stage with `-q qemu-arm`, so every guest execution is translated through QEMU rather than the host ELF loader;
3. the completed base is cached at:

```text
~/.cache/armhf16k/trixie-armhf-proot.tar.gz
```

PRoot provides a userspace chroot and binfmt layer. Kernel `binfmt_misc`, sbuild user namespaces, and host Multi-Arch build-dependency installation are not required by the current build path.

QEMU is build-time scaffolding only. Produced packages are normal ARMHF binaries and must pass the direct 16K ELF verifier before they are published.

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
3. derives a local package version from the current ARMHF binary candidate and appends the ARMHF16K revision;
4. persists the 16K linker policy in `debian/rules`;
5. extracts a disposable copy of the cached ARMHF filesystem;
6. runs `apt-get build-dep` and `dpkg-buildpackage -B` inside PRoot with `-q qemu-arm`;
7. exposes the local `armhf16k/repo/` to the guest APT resolver so earlier rebuilt packages can satisfy dependencies;
8. validates every ARM ELF in every generated `.deb` before publishing it.

The local revision defaults to `16k2`. For Debian binary NMUs such as `...+b1`, the rebuilder bases the local version on that full binary candidate before appending `+16k2`, so APT considers the ARMHF16K package newer than the binary it replaces.

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

`llvm-toolchain-19` is intentionally late in the build because it is much larger than the other source packages and will be substantially slower under QEMU user-mode than the smaller stages.

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

The installer requests only the binary packages observed as incompatible. APT resolves same-source dependencies from the local repository when required. After installation, the recursive auditor runs again and fails if any GL/EGL closure library is still 16K-incompatible.

## Package updates

Re-run the audit after ARMHF library upgrades. If a newer Debian binary/source becomes the candidate and is not 16K-compatible, rebuild that source again; the rebuilder derives its local revision from the current candidate so the rebuilt package follows the Debian update rather than permanently pinning an older base.

## Scope

This runtime layer fixes host-side ARMHF ELF layout. It is distinct from the Box86 guest-side patches under `patches/16k/`:

1. Box86 guest ELF/mprotect support lets 4K-oriented i386 programs execute on a 16K host.
2. ARMHF16K rebuilds native libraries that Box86 wraps so the host dynamic loader can map them on the same 16K kernel.

Both layers are required for full native-wrapper workloads such as Steam on the Raspberry Pi 5 16K kernel.
