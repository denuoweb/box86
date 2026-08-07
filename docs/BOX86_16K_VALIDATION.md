# Box86 16K validation status

## Completed before publication

- All three patch files parse as unified patches.
- Shell scripts pass syntax checks.
- The pure mapping-model regression passes.
- The generated fixture is a static ELF32 / EM_386 executable with two 4K-aligned PT_LOAD segments at `0x08049000` and `0x0804a000`.
- The standalone source-kit Debian package layout was verified during artifact creation.

## Target Raspberry Pi 5 acceptance

1. `getconf PAGESIZE` must return `16384`.
2. Build the armhf package with `./scripts/build-box86-16k-deb.sh`.
3. Install the generated `.deb`.
4. Run `BOX86_BIN=box86-16k ./tests/box86-16k/test_16k_elfloader.sh`; require `BOX86_16K_ELF_OK`.
5. Run `BOX86_BIN=box86-16k ./tests/box86-16k/test_steam_16k.sh`; require no `0x309e9f8a / FF FF FF FF FF FF` signature.
6. Repeat Steam with dynarec enabled after interpreter validation.

The final ARMHF/16K execution stage is implemented and ready for target validation; it has not been claimed as passed until run on the target Pi 5.
