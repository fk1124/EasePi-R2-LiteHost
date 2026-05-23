#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

usage() {
    cat <<USAGE
Usage:
  bash build-image.sh armbian bookworm 6.1 minimal
  bash build-image.sh armbian trixie 6.18 minimal
  bash build-image.sh armbian trixie 7.0 minimal
  bash build-image.sh armbian bookworm 6.1 slim
  bash build-image.sh armbian trixie 6.18 slim
  bash build-image.sh armbian trixie 7.0 slim

EasePi-R2-LiteHost builds lightweight Armbian host images for LXC OpenWrt,
LXC Debian, and Redroid on EasePi-R2.

Image types:
  minimal -> standard LiteHost with common runtime packages preinstalled
  slim    -> fast-build LiteHost base; install network/LXC/Redroid extras later

Kernel aliases:
  6.1  -> vendor
  6.18 -> current
  7.0  -> linux7
USAGE
}

fail_usage() {
    echo "ERROR: $*" >&2
    echo >&2
    usage >&2
    exit 1
}

normalize_kernel() {
    case "$1" in
        6.1|vendor)
            printf '%s\n' "vendor"
            ;;
        6.18|current)
            printf '%s\n' "current"
            ;;
        7.0|linux7)
            printf '%s\n' "linux7"
            ;;
        *)
            fail_usage "unsupported kernel profile: $1"
            ;;
    esac
}

SYSTEM="${1:-}"
RELEASE="${2:-}"
KERNEL="${3:-}"
IMAGE_TYPE="${4:-}"

case "${SYSTEM}" in
    -h|--help|help)
        usage
        exit 0
        ;;
esac

[ "$#" -eq 4 ] || fail_usage "expected exactly 4 arguments"
[ -n "${SYSTEM}" ] || fail_usage "missing system"
[ -n "${RELEASE}" ] || fail_usage "missing release"
[ -n "${KERNEL}" ] || fail_usage "missing kernel"
[ -n "${IMAGE_TYPE}" ] || fail_usage "missing image_type"

KERNEL_PROFILE="$(normalize_kernel "${KERNEL}")"

case "${SYSTEM}:${RELEASE}:${KERNEL_PROFILE}:${IMAGE_TYPE}" in
    armbian:bookworm:vendor:minimal|\
    armbian:trixie:current:minimal|\
    armbian:trixie:linux7:minimal|\
    armbian:bookworm:vendor:slim|\
    armbian:trixie:current:slim|\
    armbian:trixie:linux7:slim)
        exec bash "${REPO_DIR}/build.sh" "${KERNEL_PROFILE}" "${RELEASE}" "${IMAGE_TYPE}"
        ;;
    *)
        fail_usage "unsupported LiteHost target: ${SYSTEM} ${RELEASE} ${KERNEL} ${IMAGE_TYPE}"
        ;;
esac
