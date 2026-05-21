# EasePi-R2-LiteHost

**EasePi-R2** 精简 Armbian minimal 镜像构建项目。

本仓库从 [EasePi-R2-Image-Build](https://github.com/fk1124/EasePi-R2-Image-Build) 精简而来，只保留 LiteHost 需要的 3 个 Armbian minimal 镜像目标，方便后续在固定基础镜像上做精改。

## 编译环境要求

推荐系统：

```text
Debian 13
Debian 12
Ubuntu 24.04 LTS
```

推荐配置：

```text
CPU：4 核以上，推荐 8 核以上
内存：8GB 起步，推荐 16GB 以上
磁盘：100GB 起步，推荐 150GB 以上
网络：能正常访问 GitHub、Debian/Armbian 软件源
```

## 一、安装依赖

```bash
sudo apt update
sudo apt install -y git curl wget rsync unzip xz-utils ca-certificates
sudo apt install -y build-essential gcc g++ make bc bison flex
sudo apt install -y libssl-dev libncurses-dev python3 python3-pip python3-setuptools
sudo apt install -y file cpio qemu-user-static binfmt-support debootstrap
sudo apt install -y parted gdisk dosfstools e2fsprogs util-linux u-boot-tools
sudo apt install -y zstd kmod
```

## 二、拉取源码

```bash
mkdir -p ~/rk3588_build
cd ~/rk3588_build

GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git clone --depth=1 https://github.com/armbian/build.git build
GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git clone https://github.com/fk1124/EasePi-R2-LiteHost.git

cd EasePi-R2-LiteHost
chmod +x build-image.sh build.sh scripts/*.sh
```

目录结构应为：

```text
~/rk3588_build/
|-- build/                  # Armbian 官方 build 源码
'-- EasePi-R2-LiteHost/     # 本仓库
    |-- build-image.sh      # 统一构建入口，只接受 3 个目标
    |-- build.sh            # Armbian minimal 构建入口
    |-- configs/            # LiteHost 目标矩阵
    |-- scripts/            # 构建辅助脚本
    '-- userpatches/        # EasePi-R2 板级、内核、U-Boot、overlay 适配
```

## 三、开始编译

进入项目目录：

```bash
cd ~/rk3588_build/EasePi-R2-LiteHost
```

支持的镜像：

| 镜像 | 内核档 | 编译命令 |
| --- | --- | --- |
| Armbian bookworm 6.1 minimal | vendor | `bash build-image.sh armbian bookworm 6.1 minimal` |
| Armbian trixie 6.18 minimal | current | `bash build-image.sh armbian trixie 6.18 minimal` |
| Armbian trixie 7.0 minimal | linux7 | `bash build-image.sh armbian trixie 7.0 minimal` |

示例：

```bash
bash build-image.sh armbian bookworm 6.1 minimal
```

如果 Armbian build 目录不在 `../build`，手动指定：

```bash
ARMBIAN_BUILD_DIR=/path/to/build bash build-image.sh armbian trixie 6.18 minimal
```

## 四、说明

- 本仓库只做 Armbian minimal，不包含 server、desktop、Debian/Ubuntu BSP、Alpine、Fedora、Arch、Kali、OpenWrt 等目标。
- `6.1` 映射到 `vendor`，`6.18` 映射到 `current`，`7.0` 映射到 `linux7`。
- 构建输出仍由 Armbian build 系统写入 `build/output/images/`。
- 常用参数示例：`CPUTHREADS=8`、`REGIONAL_MIRROR=china`、`MAINLINE_MIRROR=google`。
