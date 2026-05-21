# EasePi-R2-LiteHost

Focused EasePi-R2 Armbian minimal image build kit.

This project is split from `EasePi-R2-Image-Build` and only keeps these three build targets:

```bash
bash build-image.sh armbian bookworm 6.1 minimal
bash build-image.sh armbian trixie 6.18 minimal
bash build-image.sh armbian trixie 7.0 minimal
```

## Layout

```text
build-image.sh                 Public dispatcher for the three LiteHost targets
build.sh                       Native Armbian minimal image adapter
configs/build-matrix.yaml      Target matrix
scripts/                       Armbian helper scripts
userpatches/                   EasePi-R2 board, kernel, U-Boot, and overlay patches
```

## Build

Place this project beside the Armbian build tree:

```text
rk3588_build/
  build/
  EasePi-R2-LiteHost/
```

Then run one target from `EasePi-R2-LiteHost/`:

```bash
bash build-image.sh armbian bookworm 6.1 minimal
```

If the Armbian build tree is elsewhere, set `ARMBIAN_BUILD_DIR`:

```bash
ARMBIAN_BUILD_DIR=/path/to/build bash build-image.sh armbian trixie 6.18 minimal
```
