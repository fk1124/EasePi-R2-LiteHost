# Project Structure

`EasePi-R2-LiteHost` is a focused Armbian minimal image build kit for EasePi-R2.

```text
build-image.sh                 Public dispatcher for the three LiteHost targets
build.sh                       Native Armbian minimal image adapter
configs/build-matrix.yaml      LiteHost target matrix
scripts/armbian-patch-guard.sh Armbian patch compatibility helper
scripts/sync-root-scripts.sh   Optional root script sync helper
userpatches/                   EasePi-R2 board, kernel, U-Boot, and overlay patches
work/                          Temporary generated userpatches and caches, ignored by Git
```

## Kept Targets

```bash
bash build-image.sh armbian bookworm 6.1 minimal
bash build-image.sh armbian trixie 6.18 minimal
bash build-image.sh armbian trixie 7.0 minimal
```

## Boundaries

- `build-image.sh` only accepts the three LiteHost targets.
- `build.sh` only runs native Armbian minimal builds.
- `userpatches/kernel/rk35xx-vendor-6.1/` serves the Bookworm 6.1 vendor target.
- `userpatches/kernel/archive/rockchip64-6.18/` serves the Trixie 6.18 current target.
- `userpatches/kernel/archive/rockchip64-7.0/` serves the Trixie 7.0 linux7 target.
- `userpatches/u-boot/v2025.10/` is kept for mainline U-Boot.
- `userpatches/u-boot/legacy/u-boot-radxa-rk35xx/` is trimmed to the vendor U-Boot defconfig used by the 6.1 target.
