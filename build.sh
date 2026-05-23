#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD_DIR="${ARMBIAN_BUILD_DIR:-${REPO_DIR}/../build}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"
GENERATED_USERPATCHES_DIR="${WORK_DIR}/userpatches.generated"

source "${REPO_DIR}/scripts/armbian-patch-guard.sh"

BOARD="${BOARD:-easepi-r2}"
BRANCH="${1:-current}"
RELEASE="${2:-trixie}"
IMAGE_TYPE="${3:-minimal}"
ARMBIAN_BRANCH="${BRANCH}"
EASEPI_R2_KERNEL_PROFILE="${EASEPI_R2_KERNEL_PROFILE:-}"

usage() {
    cat <<USAGE
Usage:
  bash build.sh vendor bookworm minimal
  bash build.sh current trixie minimal
  bash build.sh linux7 trixie minimal
  bash build.sh vendor bookworm slim
  bash build.sh current trixie slim
  bash build.sh linux7 trixie slim

Prefer the public dispatcher:
  bash build-image.sh armbian bookworm 6.1 minimal
  bash build-image.sh armbian trixie 6.18 minimal
  bash build-image.sh armbian trixie 7.0 minimal
  bash build-image.sh armbian bookworm 6.1 slim
  bash build-image.sh armbian trixie 6.18 slim
  bash build-image.sh armbian trixie 7.0 slim
USAGE
}

case "${BRANCH}" in
    current|vendor|linux7) ;;
    *)
        echo "ERROR: unsupported BRANCH: ${BRANCH}"
        usage
        exit 1
        ;;
esac

if [ "${BRANCH}" = "linux7" ]; then
    ARMBIAN_BRANCH="edge"
    EASEPI_R2_KERNEL_PROFILE="linux7"
fi

case "${BRANCH}:${RELEASE}:${IMAGE_TYPE}" in
    vendor:bookworm:minimal|current:trixie:minimal|linux7:trixie:minimal|\
    vendor:bookworm:slim|current:trixie:slim|linux7:trixie:slim) ;;
    *)
        echo "ERROR: unsupported LiteHost target: ${BRANCH} ${RELEASE} ${IMAGE_TYPE}"
        usage
        exit 1
        ;;
esac

if [ ! -f "${BUILD_DIR}/compile.sh" ]; then
    echo "ERROR: Cannot find Armbian build directory: ${BUILD_DIR}"
    echo
    echo "Expected structure:"
    echo "  ~/rk3588_build/"
    echo "  |-- build/"
    echo "  '-- EasePi-R2-LiteHost/"
    echo
    echo "Or specify manually:"
    echo "  ARMBIAN_BUILD_DIR=/path/to/build bash build.sh current trixie minimal"
    echo "  ARMBIAN_BUILD_DIR=/path/to/build bash build.sh linux7 trixie minimal"
    exit 1
fi

# ============================================================
# 默认构建策略
# ============================================================
#
# 关键点：
# 1. REGIONAL_MIRROR 默认留空，不再默认 china。
#    你的环境直连 GitHub / ghcr.io 反而更快。
#
# 2. MAINLINE_MIRROR 默认 auto，优先 google，再 tuna，再 bfsu。
#
# 3. UBOOT_MIRROR 默认 auto，固定使用 github。
#
# 4. GITHUB_SOURCE 默认 auto，优先 github.com。
#
# 5. GITHUB_MIRROR 固定留空，GitHub Release 直连下载。
#
# 6. KERNEL_GIT 默认 shallow，避免 full 拉 3GB+。
#
# 7. CPUTHREADS 尊重外部传入，不再强制覆盖。
#
# 手动示例：
#   CPUTHREADS=8 bash build.sh current trixie minimal
#   MAINLINE_MIRROR=google bash build.sh current trixie minimal
#   REGIONAL_MIRROR=china bash build.sh current trixie minimal

REGIONAL_MIRROR="${REGIONAL_MIRROR-}"
MAINLINE_MIRROR="${MAINLINE_MIRROR:-auto}"
UBOOT_MIRROR="${UBOOT_MIRROR:-auto}"
GITHUB_SOURCE="${GITHUB_SOURCE:-https://github.com}"
GITHUB_MIRROR=""
KERNEL_GIT="${KERNEL_GIT:-shallow}"
CPUTHREADS="${CPUTHREADS:-$(nproc)}"
EASEPI_R2_INHERIT_HOST_GIT_CONFIG="${EASEPI_R2_INHERIT_HOST_GIT_CONFIG:-no}"
case "${IMAGE_TYPE}" in
    slim)
        EASEPI_R2_LITEHOST_PROFILE="${EASEPI_R2_LITEHOST_PROFILE:-slim}"
        ;;
    minimal)
        EASEPI_R2_LITEHOST_PROFILE="${EASEPI_R2_LITEHOST_PROFILE:-standard}"
        ;;
esac

ORAS_PREFETCH="${ORAS_PREFETCH:-yes}"
ORAS_VERSION="${ORAS_VERSION:-1.3.1}"

msg() {
    printf '%s\n' "$*"
}

setup_github_direct_git_config() {
    case "${EASEPI_R2_INHERIT_HOST_GIT_CONFIG}" in
        yes|1|true|TRUE)
            return 0
            ;;
        no|0|false|FALSE)
            ;;
        *)
            echo "ERROR: unsupported EASEPI_R2_INHERIT_HOST_GIT_CONFIG=${EASEPI_R2_INHERIT_HOST_GIT_CONFIG}" >&2
            echo "Use no to force direct GitHub access, or yes to inherit host git config." >&2
            exit 1
            ;;
    esac

    local git_config="${WORK_DIR}/gitconfig.github-direct"

    mkdir -p "${WORK_DIR}"
    {
        printf '[core]\n'
        printf '\taskPass =\n'
        printf '[credential]\n'
        printf '\thelper =\n'
        printf '[safe]\n'
        printf '\tdirectory = *\n'
    } > "${git_config}"

    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="${git_config}"
}

append_csv_value() {
    local csv="${1-}"
    local value="$2"

    case ",${csv}," in
        *,"${value}",*)
            printf '%s\n' "${csv}"
            return 0
            ;;
    esac

    if [ -z "${csv}" ]; then
        printf '%s\n' "${value}"
    else
        printf '%s,%s\n' "${csv}" "${value}"
    fi
}

remove_matching_files() {
    local pattern file removed=0

    shopt -s nullglob
    for pattern in "$@"; do
        for file in ${pattern}; do
            rm -f "${file}"
            msg "Removed stale artifact: ${file}"
            removed=1
        done
    done
    shopt -u nullglob

    return "${removed}"
}

prepare_vendor_clean_build() {
    [ "${BRANCH}" = "vendor" ] || return 0
    [ "${EASEPI_R2_VENDOR_CLEAN_BUILD:-yes}" = "yes" ] || {
        msg "Vendor clean rebuild disabled by EASEPI_R2_VENDOR_CLEAN_BUILD=${EASEPI_R2_VENDOR_CLEAN_BUILD:-no}"
        return 0
    }

    msg
    msg "Vendor branch: forcing clean kernel/u-boot/BSP rebuild to avoid stale local deb reuse."

    CLEAN_LEVEL="$(append_csv_value "${CLEAN_LEVEL-}" "make-kernel")"
    CLEAN_LEVEL="$(append_csv_value "${CLEAN_LEVEL}" "make-uboot")"

    remove_matching_files \
        "${BUILD_DIR}/output/debs/linux-image-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-dtb-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-headers-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-libc-dev-vendor-rk35xx_"*.deb \
        "${BUILD_DIR}/output/debs/linux-u-boot-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/debs/armbian-bsp-cli-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/packages-hashed/kernel-rk35xx-vendor_"*.tar \
        "${BUILD_DIR}/output/packages-hashed/linux-u-boot-${BOARD}-vendor_"*.deb \
        "${BUILD_DIR}/output/packages-hashed/armbian-bsp-cli-${BOARD}-vendor_"*.tar || true
}

install_pv_cat_wrapper() {
    local wrapper_dir
    wrapper_dir="$(mktemp -d "${TMPDIR:-/tmp}/easepi-r2-pv.XXXXXX")"
    cat > "${wrapper_dir}/pv" <<'PV_WRAPPER'
#!/usr/bin/env bash
set -e

files=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --)
            shift
            while [ "$#" -gt 0 ]; do
                files+=("$1")
                shift
            done
            ;;
        -N|--name|-s|--size|-i|--interval|-w|--width|-H|--height|-L|--rate-limit|-B|--buffer-size|-A|--last-written|-F|--format|-o|--output)
            shift
            [ "$#" -gt 0 ] && shift || true
            ;;
        --*=*)
            shift
            ;;
        -*)
            shift
            ;;
        *)
            files+=("$1")
            shift
            ;;
    esac
done

if [ "${#files[@]}" -gt 0 ]; then
    exec cat -- "${files[@]}"
fi
exec cat
PV_WRAPPER
    chmod +x "${wrapper_dir}/pv"
    printf '%s\n' "${wrapper_dir}"
}

probe_git() {
    local name="$1"
    local url="$2"
    local ref="${3:-HEAD}"
    local timeout_sec="${4:-15}"

    printf 'Probe git %-20s : %s ... ' "${name}" "${url}"

    if timeout "${timeout_sec}" git ls-remote --exit-code "${url}" "${ref}" >/dev/null 2>&1; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAIL\n'
    return 1
}

probe_url() {
    local name="$1"
    local url="$2"
    local timeout_sec="${3:-15}"

    printf 'Probe url %-20s : %s ... ' "${name}" "${url}"

    if timeout "${timeout_sec}" curl -fsIL --connect-timeout 8 --max-time "${timeout_sec}" "${url}" >/dev/null 2>&1; then
        printf 'OK\n'
        return 0
    fi

    printf 'FAIL\n'
    return 1
}

choose_mainline_mirror() {
    if [ "${BRANCH}" = "vendor" ]; then
        MAINLINE_MIRROR=""
        return 0
    fi

    if [ "${MAINLINE_MIRROR}" != "auto" ]; then
        return 0
    fi

    msg
    msg "Auto selecting mainline kernel mirror..."

    if probe_git "linux Google" "https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="google"
        return 0
    fi

    if probe_git "linux TUNA" "https://mirrors.tuna.tsinghua.edu.cn/git/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="tuna"
        return 0
    fi

    if probe_git "linux BFSU" "https://mirrors.bfsu.edu.cn/git/linux-stable.git" "HEAD" 15; then
        MAINLINE_MIRROR="bfsu"
        return 0
    fi

    msg "WARN: Google/TUNA/BFSU unavailable, using Armbian default mainline source."
    MAINLINE_MIRROR=""
}

choose_uboot_mirror() {
    if [ "${BRANCH}" = "vendor" ]; then
        if [ "${UBOOT_MIRROR}" = "auto" ]; then
            UBOOT_MIRROR=""
        fi
        return 0
    fi

    if [ "${UBOOT_MIRROR}" != "auto" ] && [ "${UBOOT_MIRROR}" != "github" ]; then
        msg "WARN: ignoring UBOOT_MIRROR=${UBOOT_MIRROR}; using github."
    fi

    msg
    msg "Using GitHub U-Boot source..."

    if probe_git "u-boot GitHub" "https://github.com/u-boot/u-boot.git" "HEAD" 15; then
        UBOOT_MIRROR="github"
        return 0
    fi

    msg "WARN: GitHub U-Boot probe failed, still using github."
    UBOOT_MIRROR="github"
}

choose_github_source() {
    local oras_file="oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    local direct_url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${oras_file}"

    msg
    msg "Using GitHub direct release source..."

    if probe_url "GitHub direct" "${direct_url}" 15; then
        GITHUB_SOURCE="https://github.com"
        return 0
    fi

    msg "WARN: GitHub direct release probe failed, still using https://github.com."
    GITHUB_SOURCE="https://github.com"
}

set_kernel_config_not_set() {
    local file="$1"
    local name="$2"

    sed -i -E "/^${name}=|^# ${name} is not set/d" "${file}"
    printf '# %s is not set\n' "${name}" >> "${file}"
}

set_kernel_config_value() {
    local file="$1"
    local name="$2"
    local value="$3"

    sed -i -E "/^${name}=|^# ${name} is not set/d" "${file}"
    printf '%s=%s\n' "${name}" "${value}" >> "${file}"
}

enable_vfio_iommu_capabilities() {
    local file="$1"
    local cfg="$2"

    if [ "${cfg}" = "linux-rk35xx-vendor.config" ]; then
        set_kernel_config_value "${file}" "CONFIG_VFIO" "y"
        set_kernel_config_value "${file}" "CONFIG_VFIO_PCI" "y"
        set_kernel_config_value "${file}" "CONFIG_ARM_SMMU_V3" "y"
        return 0
    fi

    set_kernel_config_value "${file}" "CONFIG_VFIO" "m"
    set_kernel_config_value "${file}" "CONFIG_VFIO_GROUP" "y"
    set_kernel_config_value "${file}" "CONFIG_VFIO_CONTAINER" "y"
    set_kernel_config_value "${file}" "CONFIG_VFIO_DEVICE_CDEV" "y"
    set_kernel_config_value "${file}" "CONFIG_VFIO_PCI" "m"
    set_kernel_config_value "${file}" "CONFIG_IOMMUFD" "y"
    set_kernel_config_value "${file}" "CONFIG_ARM_SMMU" "y"
    set_kernel_config_value "${file}" "CONFIG_ARM_SMMU_V3" "y"
    set_kernel_config_value "${file}" "CONFIG_ARM_SMMU_V3_SVA" "y"
    set_kernel_config_value "${file}" "CONFIG_ARM_SMMU_V3_IOMMUFD" "y"
}

enable_litehost_kernel_capabilities() {
    local file="$1"
    local cfg="$2"
    local option

    local host_bool_options=(
        CONFIG_POSIX_MQUEUE
        CONFIG_PSI
        CONFIG_CGROUPS
        CONFIG_BLK_CGROUP
        CONFIG_CGROUP_SCHED
        CONFIG_FAIR_GROUP_SCHED
        CONFIG_CFS_BANDWIDTH
        CONFIG_CGROUP_PIDS
        CONFIG_CGROUP_RDMA
        CONFIG_CGROUP_FREEZER
        CONFIG_CGROUP_HUGETLB
        CONFIG_CPUSETS
        CONFIG_CGROUP_DEVICE
        CONFIG_CGROUP_CPUACCT
        CONFIG_CGROUP_PERF
        CONFIG_CGROUP_BPF
        CONFIG_CGROUP_MISC
        CONFIG_MEMCG
        CONFIG_MEMCG_SWAP
        CONFIG_NAMESPACES
        CONFIG_UTS_NS
        CONFIG_IPC_NS
        CONFIG_USER_NS
        CONFIG_PID_NS
        CONFIG_NET_NS
        CONFIG_CGROUP_NS
        CONFIG_TIME_NS
        CONFIG_CHECKPOINT_RESTORE
        CONFIG_SECCOMP
        CONFIG_SECCOMP_FILTER
        CONFIG_KEYS
        CONFIG_DEVPTS_MULTIPLE_INSTANCES
        CONFIG_TMPFS_POSIX_ACL
        CONFIG_TMPFS_XATTR
        CONFIG_HUGETLBFS
        CONFIG_BPF_SYSCALL
        CONFIG_BPF_JIT
        CONFIG_BPF_LSM
        CONFIG_NETFILTER
        CONFIG_NETFILTER_ADVANCED
        CONFIG_NF_TABLES_INET
        CONFIG_NF_TABLES_NETDEV
        CONFIG_NF_TABLES_ARP
        CONFIG_BRIDGE_VLAN_FILTERING
        CONFIG_VLAN_8021Q_GVRP
        CONFIG_VLAN_8021Q_MVRP
        CONFIG_ANDROID_BINDER_IPC
        CONFIG_ANDROID_BINDERFS
        CONFIG_SQUASHFS_XATTR
        CONFIG_SQUASHFS_LZ4
        CONFIG_SQUASHFS_LZO
        CONFIG_SQUASHFS_XZ
        CONFIG_SQUASHFS_ZSTD
        CONFIG_DEVTMPFS
        CONFIG_DEVTMPFS_MOUNT
        CONFIG_KVM
    )

    local host_module_options=(
        CONFIG_BINFMT_MISC
        CONFIG_OVERLAY_FS
        CONFIG_FUSE_FS
        CONFIG_SQUASHFS
        CONFIG_EROFS_FS
        CONFIG_BLK_DEV_LOOP
        CONFIG_NBD
        CONFIG_DM_THIN_PROVISIONING
        CONFIG_BRIDGE
        CONFIG_BRIDGE_NETFILTER
        CONFIG_VLAN_8021Q
        CONFIG_VETH
        CONFIG_TUN
        CONFIG_DUMMY
        CONFIG_IFB
        CONFIG_MACVLAN
        CONFIG_MACVTAP
        CONFIG_IPVLAN
        CONFIG_VXLAN
        CONFIG_NET_SCH_INGRESS
        CONFIG_NET_SCH_FQ
        CONFIG_NET_SCH_FQ_CODEL
        CONFIG_NET_SCH_CAKE
        CONFIG_NET_CLS_CGROUP
        CONFIG_NETFILTER_XTABLES
        CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
        CONFIG_NETFILTER_XT_MATCH_COMMENT
        CONFIG_NETFILTER_XT_MATCH_CONNTRACK
        CONFIG_NETFILTER_XT_MATCH_CGROUP
        CONFIG_NETFILTER_XT_MATCH_IPVS
        CONFIG_NETFILTER_XT_MATCH_MAC
        CONFIG_NETFILTER_XT_MATCH_MARK
        CONFIG_NETFILTER_XT_MATCH_MULTIPORT
        CONFIG_NETFILTER_XT_MATCH_PHYSDEV
        CONFIG_NETFILTER_XT_MATCH_STATE
        CONFIG_NETFILTER_XT_MATCH_TCPMSS
        CONFIG_NETFILTER_XT_MATCH_U32
        CONFIG_NETFILTER_XT_TARGET_CHECKSUM
        CONFIG_NETFILTER_XT_TARGET_MASQUERADE
        CONFIG_NETFILTER_XT_TARGET_REDIRECT
        CONFIG_NETFILTER_XT_TARGET_TCPMSS
        CONFIG_NF_TABLES
        CONFIG_NF_TABLES_BRIDGE
        CONFIG_NFT_BRIDGE_META
        CONFIG_NFT_BRIDGE_REJECT
        CONFIG_NFT_COMPAT
        CONFIG_NFT_CT
        CONFIG_NFT_FIB_INET
        CONFIG_NFT_FLOW_OFFLOAD
        CONFIG_NFT_LIMIT
        CONFIG_NFT_LOG
        CONFIG_NFT_MASQ
        CONFIG_NFT_NAT
        CONFIG_NFT_REDIR
        CONFIG_NFT_REJECT
        CONFIG_NFT_TPROXY
        CONFIG_NFT_TUNNEL
        CONFIG_NF_CONNTRACK
        CONFIG_NF_NAT
        CONFIG_NF_FLOW_TABLE
        CONFIG_IP_SET
        CONFIG_IP_NF_IPTABLES
        CONFIG_IP_NF_FILTER
        CONFIG_IP_NF_NAT
        CONFIG_IP_NF_TARGET_MASQUERADE
        CONFIG_IP_NF_TARGET_REDIRECT
        CONFIG_IP_NF_MANGLE
        CONFIG_IP_NF_RAW
        CONFIG_IP6_NF_IPTABLES
        CONFIG_IP6_NF_FILTER
        CONFIG_IP6_NF_NAT
        CONFIG_IP6_NF_TARGET_MASQUERADE
        CONFIG_IP6_NF_MANGLE
        CONFIG_IP6_NF_RAW
        CONFIG_BRIDGE_NF_EBTABLES
        CONFIG_BRIDGE_EBT_T_FILTER
        CONFIG_BRIDGE_EBT_T_NAT
        CONFIG_BRIDGE_EBT_BROUTE
        CONFIG_NFS_FS
        CONFIG_NFSD
        CONFIG_CIFS
        CONFIG_ISCSI_TCP
        CONFIG_ISCSI_TARGET
        CONFIG_ZRAM
        CONFIG_CRYPTO_USER
        CONFIG_CRYPTO_USER_API_HASH
        CONFIG_CRYPTO_USER_API_SKCIPHER
        CONFIG_CRYPTO_USER_API_RNG
        CONFIG_CRYPTO_USER_API_AEAD
    )

    for option in "${host_bool_options[@]}"; do
        set_kernel_config_value "${file}" "${option}" "y"
    done

    for option in "${host_module_options[@]}"; do
        set_kernel_config_value "${file}" "${option}" "m"
    done

    set_kernel_config_value "${file}" "CONFIG_ANDROID_BINDER_DEVICES" '"binder,hwbinder,vndbinder,anbox-binder,anbox-hwbinder,anbox-vndbinder"'
    set_kernel_config_value "${file}" "CONFIG_ASHMEM" "y"

    if [ "${cfg}" = "linux-rk35xx-vendor.config" ]; then
        set_kernel_config_value "${file}" "CONFIG_DRM_PANTHOR" "m"
        set_kernel_config_value "${file}" "CONFIG_DRM_PANFROST" "m"
    fi
}

prepare_kernel_configs() {
    bash "${REPO_DIR}/scripts/sync-root-scripts.sh"

    rm -rf "${GENERATED_USERPATCHES_DIR}"
    mkdir -p "${GENERATED_USERPATCHES_DIR}"
    rsync -a "${REPO_DIR}/userpatches/" "${GENERATED_USERPATCHES_DIR}/"

    local cfg src repo_dst dst found refresh
    local configs=(
        "linux-rockchip64-current.config"
        "linux-rockchip64-edge.config"
        "linux-rk35xx-vendor.config"
    )

    refresh="${EASEPI_R2_REFRESH_KERNEL_CONFIG_TEMPLATES:-${EASEPI_R2_REFRESH_KERNEL_CONFIGS:-no}}"

    for cfg in "${configs[@]}"; do
        src="${BUILD_DIR}/config/kernel/${cfg}"
        repo_dst="${REPO_DIR}/userpatches/${cfg}"
        dst="${GENERATED_USERPATCHES_DIR}/${cfg}"
        found=""

        if [ -f "${src}" ]; then
            found="${src}"
        else
            found="$(find "${BUILD_DIR}/config" -type f -name "${cfg}" 2>/dev/null | head -1 || true)"
        fi

        if [ "${refresh}" = "yes" ] && [ -n "${found}" ] && [ -f "${found}" ]; then
            mkdir -p "${REPO_DIR}/userpatches"
            cp -f "${found}" "${repo_dst}"
            cp -f "${found}" "${dst}"
            msg "Refreshed kernel config template: ${repo_dst}"
        elif [ -f "${dst}" ]; then
            msg "Reuse generated kernel config from repository template: ${dst}"
        elif [ -n "${found}" ] && [ -f "${found}" ]; then
            cp -f "${found}" "${dst}"
        else
            msg "WARN: default kernel config not found and user config missing: ${cfg}"
            continue
        fi

        # 关闭 WERROR，避免 warning 被当成 error 导致编译中断。
        sed -i \
            -e 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' \
            -e 's/^CONFIG_WERROR=.*/# CONFIG_WERROR is not set/' \
            "${dst}"

        grep -q '^# CONFIG_WERROR is not set' "${dst}" || \
            echo '# CONFIG_WERROR is not set' >> "${dst}"

        # 禁用 panel-simple-dsi。
        # 这是 MIPI DSI 小屏驱动，不是 HDMI。EasePi-R2 常规 HDMI 输出不依赖它。
        sed -i \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=y/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=m/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            -e 's/^CONFIG_DRM_PANEL_SIMPLE_DSI=.*/# CONFIG_DRM_PANEL_SIMPLE_DSI is not set/' \
            "${dst}"

        grep -q '^# CONFIG_DRM_PANEL_SIMPLE_DSI is not set' "${dst}" || \
            echo '# CONFIG_DRM_PANEL_SIMPLE_DSI is not set' >> "${dst}"

        enable_vfio_iommu_capabilities "${dst}" "${cfg}"
        enable_litehost_kernel_capabilities "${dst}" "${cfg}"

        if [ "${cfg}" = "linux-rk35xx-vendor.config" ]; then
            set_kernel_config_value "${dst}" "CONFIG_R8125" "m"
            set_kernel_config_value "${dst}" "CONFIG_RTL8852BS" "m"
            set_kernel_config_value "${dst}" "CONFIG_DRM_PANFROST" "m"
            set_kernel_config_value "${dst}" "CONFIG_DRM_PANTHOR" "m"
            set_kernel_config_value "${dst}" "CONFIG_AP6XXX" "m"
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_PCIE" "y"
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_FW_PATH" '"/lib/firmware/ap6275p/fw_bcmdhd.bin"'
            set_kernel_config_value "${dst}" "CONFIG_BCMDHD_NVRAM_PATH" '"/lib/firmware/ap6275p/nvram.txt"'
            set_kernel_config_value "${dst}" "CONFIG_BRCMFMAC" "m"
            set_kernel_config_value "${dst}" "CONFIG_BRCMFMAC_SDIO" "y"
            set_kernel_config_value "${dst}" "CONFIG_BT_HCIUART_BCM" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_DEVFREQ" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_MIDGARD" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_EXPERT" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_THIRDPARTY" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_THIRDPARTY_NAME" '"rk"'
            set_kernel_config_value "${dst}" "CONFIG_MALI_BIFROST" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_PLATFORM_NAME" '"rk"'
            set_kernel_config_value "${dst}" "CONFIG_MALI_CSF_SUPPORT" "y"
            set_kernel_config_value "${dst}" "CONFIG_MALI_BIFROST_EXPERT" "y"
        else
            set_kernel_config_not_set "${dst}" "CONFIG_RTL8852BS"
        fi

        msg "Prepared generated kernel config: ${dst}"
    done
}

prefetch_oras_tooling() {
    if [ "${ORAS_PREFETCH}" != "yes" ]; then
        msg "ORAS prefetch disabled."
        return 0
    fi

    local uname_s uname_m oras_os oras_arch oras_version oras_dir oras_fn oras_bin oras_url tmp_dir

    uname_s="$(uname -s)"
    uname_m="$(uname -m)"
    oras_version="${ORAS_VERSION}"

    case "${uname_s}" in
        Linux|linux)
            oras_os="linux"
            ;;
        Darwin|darwin)
            oras_os="darwin"
            ;;
        *)
            msg "WARN: unsupported host OS for ORAS prefetch: ${uname_s}"
            return 0
            ;;
    esac

    case "${uname_m}" in
        x86_64|amd64)
            oras_arch="amd64"
            ;;
        aarch64|arm64)
            oras_arch="arm64"
            ;;
        riscv64)
            oras_arch="riscv64"
            oras_version="1.2.0-beta.1"
            ;;
        *)
            msg "WARN: unsupported host arch for ORAS prefetch: ${uname_m}"
            return 0
            ;;
    esac

    oras_dir="${BUILD_DIR}/cache/tools/oras"
    oras_fn="oras_${oras_version}_${oras_os}_${oras_arch}"
    oras_bin="${oras_dir}/${oras_fn}"
    oras_url="${GITHUB_SOURCE%/}/oras-project/oras/releases/download/v${oras_version}/${oras_fn}.tar.gz"

    mkdir -p "${oras_dir}"

    if [ -x "${oras_bin}" ]; then
        msg "Using cached ORAS tooling: ${oras_bin}"
        return 0
    fi

    msg
    msg "Prefetch ORAS tooling:"
    msg "  URL : ${oras_url}"
    msg "  SAVE: ${oras_bin}"

    tmp_dir="$(mktemp -d)"

    if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 \
        -o "${tmp_dir}/oras.tar.gz" \
        "${oras_url}"; then
        rm -rf "${tmp_dir}"
        msg "WARN: failed to prefetch ORAS tooling, continue with Armbian default behavior."
        return 0
    fi

    tar -xf "${tmp_dir}/oras.tar.gz" -C "${tmp_dir}" oras
    mv "${tmp_dir}/oras" "${oras_bin}"
    chmod +x "${oras_bin}"

    "${oras_bin}" version || true

    rm -rf "${tmp_dir}"
}

trust_existing_git_caches() {
    # The generated direct-GitHub config already sets safe.directory=*.
    return 0
}

setup_github_direct_git_config
choose_mainline_mirror
choose_uboot_mirror
choose_github_source
prepare_kernel_configs
prepare_vendor_clean_build

printf '============================================\n'
printf '  EasePi-R2 LiteHost Image Build\n'
printf '============================================\n'
printf 'Build directory : %s\n' "${BUILD_DIR}"
printf 'Board           : %s\n' "${BOARD}"
printf 'Branch          : %s\n' "${BRANCH}"
printf 'Armbian branch  : %s\n' "${ARMBIAN_BRANCH}"
printf 'Kernel profile  : %s\n' "${EASEPI_R2_KERNEL_PROFILE:-default}"
printf 'Release         : %s\n' "${RELEASE}"
printf 'Image type      : %s\n' "${IMAGE_TYPE}"
printf 'LiteHost profile: %s\n' "${EASEPI_R2_LITEHOST_PROFILE}"
printf 'Role            : LXC OpenWrt + LXC Debian + Redroid host\n'
printf 'Kernel git      : %s\n' "${KERNEL_GIT}"
printf 'Regional mirror : %s\n' "${REGIONAL_MIRROR:-none}"
printf 'Mainline mirror : %s\n' "${MAINLINE_MIRROR:-default}"
printf 'U-Boot mirror   : %s\n' "${UBOOT_MIRROR:-default}"
printf 'GitHub mirror   : %s\n' "${GITHUB_MIRROR:-direct}"
printf 'GitHub source   : %s\n' "${GITHUB_SOURCE}"
printf 'Threads         : %s\n' "${CPUTHREADS}"
printf 'Clean level     : %s\n' "${CLEAN_LEVEL:-default}"
printf '============================================\n'

rsync -a --delete "${GENERATED_USERPATCHES_DIR}/" "${BUILD_DIR}/userpatches/"

cd "${BUILD_DIR}"

export PESTER_TERMINAL=no
export WT_SESSION=1
export ALLOW_ROOT=yes
export GIT_TERMINAL_PROMPT=0
export SKIP_ORAS=yes

trust_existing_git_caches
prefetch_oras_tooling

BUILD_DESKTOP="no"
BUILD_MINIMAL="yes"

COMPILE_ARGS=(
    "BOARD=${BOARD}"
    "BRANCH=${ARMBIAN_BRANCH}"
    "RELEASE=${RELEASE}"
    "BUILD_DESKTOP=${BUILD_DESKTOP}"
    "BUILD_MINIMAL=${BUILD_MINIMAL}"
    "KERNEL_CONFIGURE=no"
    "KERNEL_GIT=${KERNEL_GIT}"
    "SKIP_ORAS=yes"
    "USE_CCACHE=yes"
    "CPUTHREADS=${CPUTHREADS}"
    "GITHUB_SOURCE=${GITHUB_SOURCE}"
    "GITHUB_MIRROR=${GITHUB_MIRROR}"
    "ORAS_VERSION=${ORAS_VERSION}"
)

if [ -n "${EASEPI_R2_KERNEL_PROFILE}" ]; then
    COMPILE_ARGS+=("EASEPI_R2_KERNEL_PROFILE=${EASEPI_R2_KERNEL_PROFILE}")
fi

COMPILE_ARGS+=("EASEPI_R2_LITEHOST_PROFILE=${EASEPI_R2_LITEHOST_PROFILE}")

if [ "${EASEPI_R2_KERNEL_PROFILE}" = "linux7" ]; then
    COMPILE_ARGS+=(
        "KERNEL_MAJOR_MINOR=7.0"
        "KERNELBRANCH=branch:linux-7.0.y"
        "KERNELPATCHDIR=archive/rockchip64-7.0"
    )
fi

if [ -n "${REGIONAL_MIRROR}" ]; then
    COMPILE_ARGS+=("REGIONAL_MIRROR=${REGIONAL_MIRROR}")
fi

if [ -n "${MAINLINE_MIRROR}" ]; then
    COMPILE_ARGS+=("MAINLINE_MIRROR=${MAINLINE_MIRROR}")
fi

if [ -n "${UBOOT_MIRROR}" ]; then
    COMPILE_ARGS+=("UBOOT_MIRROR=${UBOOT_MIRROR}")
fi

if [ -n "${CLEAN_LEVEL:-}" ]; then
    COMPILE_ARGS+=("CLEAN_LEVEL=${CLEAN_LEVEL}")
fi

printf '\nStarting build...\n\n'

PV_WRAPPER_DIR=""
if [ "${EASEPI_R2_DISABLE_ARMBIAN_PV:-yes}" = "yes" ]; then
    PV_WRAPPER_DIR="$(install_pv_cat_wrapper)"
    printf 'Using cat-based pv wrapper to avoid rootfs extraction stalls.\n\n'
fi

cleanup_build_helpers() {
    easepi_r2_restore_armbian_patches
    if [ -n "${PV_WRAPPER_DIR:-}" ]; then
        rm -rf "${PV_WRAPPER_DIR}"
    fi
}

trap cleanup_build_helpers EXIT
easepi_r2_disable_known_bad_armbian_patches "${BUILD_DIR}"

set +e
# Keep the Armbian build non-interactive without feeding an infinite stream into
# every child process. Some extraction/logging pipelines inherit stdin; piping
# `yes` into the whole build can make them wait on the wrong input forever.
PATH="${PV_WRAPPER_DIR:+${PV_WRAPPER_DIR}:}${PATH}" ./compile.sh "${COMPILE_ARGS[@]}" </dev/null
BUILD_EXIT="$?"
set -e

if [ "${BUILD_EXIT}" -ne 0 ]; then
    echo
    echo "ERROR: Armbian build failed with exit code ${BUILD_EXIT}."
    echo
    echo "Recent logs:"
    ls -lt output/logs/*.log 2>/dev/null | head -5 || true
    echo
    echo "Quick error grep:"
    LOG="$(ls -t output/logs/log-build-*.log 2>/dev/null | head -1 || true)"
    if [ -n "${LOG}" ] && [ -f "${LOG}" ]; then
        grep -n -B5 -A15 -Ei \
            'error:|fatal error:|cc1: all warnings|Error [0-9]|No rule to make target|Killed' \
            "${LOG}" | tail -n 160 || true
    fi
    exit "${BUILD_EXIT}"
fi

echo
echo "Build finished."
echo "Images:"
ls -lh output/images 2>/dev/null || true
