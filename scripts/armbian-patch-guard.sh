#!/usr/bin/env bash

EASEPI_R2_ARMBIAN_PATCH_GUARD_DISABLED_FILES=()

easepi_r2_patch_guard_msg() {
    if declare -F msg >/dev/null 2>&1; then
        msg "$@"
    else
        printf '%s\n' "$*"
    fi
}

easepi_r2_restore_armbian_patches() {
    local patch_file disabled_file

    for patch_file in "${EASEPI_R2_ARMBIAN_PATCH_GUARD_DISABLED_FILES[@]}"; do
        disabled_file="${patch_file}.easepi-r2-disabled"
        if [ -f "${disabled_file}" ] && [ ! -f "${patch_file}" ]; then
            mv "${disabled_file}" "${patch_file}"
            easepi_r2_patch_guard_msg "Restored Armbian patch: ${patch_file}"
        fi
    done

    EASEPI_R2_ARMBIAN_PATCH_GUARD_DISABLED_FILES=()
}

easepi_r2_disable_known_bad_armbian_patches() {
    local build_dir="$1"
    local rel patch_file disabled_file
    local patch_files=(
        "patch/kernel/archive/rockchip64-6.18/rk3399-usbc-phy-rockchip-naneng-Add-fallback-for-old-DTs.patch"
        "patch/kernel/archive/rockchip64-6.18/rk3399-usbc-usb-dwc3-Extend-reset-quirk-support-to-include-role-.patch"
        "patch/kernel/archive/rockchip64-7.0/rk3399-usbc-phy-rockchip-naneng-Add-fallback-for-old-DTs.patch"
        "patch/kernel/archive/rockchip64-7.0/rk3399-usbc-usb-dwc3-Extend-reset-quirk-support-to-include-role-.patch"
    )

    if [ "${EASEPI_R2_DISABLE_RK3399_USBC_PATCHES:-yes}" != "yes" ]; then
        easepi_r2_patch_guard_msg "RK3399 USB-C patch guard disabled by EASEPI_R2_DISABLE_RK3399_USBC_PATCHES."
        return 0
    fi

    [ -d "${build_dir}/patch/kernel/archive" ] || return 0

    for rel in "${patch_files[@]}"; do
        patch_file="${build_dir}/${rel}"
        disabled_file="${patch_file}.easepi-r2-disabled"

        if [ -f "${disabled_file}" ] && [ ! -f "${patch_file}" ]; then
            mv "${disabled_file}" "${patch_file}"
            easepi_r2_patch_guard_msg "Recovered stale disabled Armbian patch: ${patch_file}"
        fi

        if [ -f "${patch_file}" ] && [ -f "${disabled_file}" ]; then
            easepi_r2_patch_guard_msg "WARN: both patch and disabled copy exist, leaving unchanged: ${patch_file}"
            continue
        fi

        if [ -f "${patch_file}" ]; then
            mv "${patch_file}" "${disabled_file}"
            EASEPI_R2_ARMBIAN_PATCH_GUARD_DISABLED_FILES+=("${patch_file}")
            easepi_r2_patch_guard_msg "Temporarily disabled Armbian RK3399 USB-C patch: ${rel}"
        fi
    done
}
