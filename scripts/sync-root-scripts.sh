#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK_DIR="${WORK_DIR:-${REPO_DIR}/work}"

SCRIPT_REPO="${EASEPI_R2_SCRIPT_REPO:-https://github.com/fk1124/EasePi-R2-Script.git}"
SCRIPT_REF="${EASEPI_R2_SCRIPT_REF:-main}"
SCRIPT_SYNC="${EASEPI_R2_SCRIPT_SYNC:-yes}"
SCRIPT_GIT_INHERIT_CONFIG="${EASEPI_R2_SCRIPT_GIT_INHERIT_CONFIG:-${EASEPI_R2_INHERIT_HOST_GIT_CONFIG:-no}}"
CACHE_DIR="${EASEPI_R2_SCRIPT_CACHE_DIR:-${WORK_DIR}/cache/easepi-r2-script}"
DEST_DIR="${1:-${REPO_DIR}/userpatches/overlay/easepi-r2-peripherals/root}"

msg() {
    printf 'EasePi-R2 script sync: %s\n' "$*"
}

if [ "${SCRIPT_SYNC}" = "no" ] || [ "${SCRIPT_SYNC}" = "0" ]; then
    msg "disabled by EASEPI_R2_SCRIPT_SYNC=${SCRIPT_SYNC}"
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to sync EasePi-R2 root scripts." >&2
    exit 1
fi

git_sync() {
    case "${SCRIPT_GIT_INHERIT_CONFIG}" in
        yes|1|true|TRUE)
            git "$@"
            ;;
        no|0|false|FALSE)
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git "$@"
            ;;
        *)
            echo "ERROR: unsupported EASEPI_R2_SCRIPT_GIT_INHERIT_CONFIG=${SCRIPT_GIT_INHERIT_CONFIG}" >&2
            echo "Use no to force direct GitHub access, or yes to inherit host git config." >&2
            exit 1
            ;;
    esac
}

tmp_dir=""
cleanup() {
    [ -z "${tmp_dir}" ] || rm -rf "${tmp_dir}"
}
trap cleanup EXIT

configure_sparse_checkout() {
    local repo_dir="$1"

    git_sync -C "${repo_dir}" config core.sparseCheckout true
    git_sync -C "${repo_dir}" config core.sparseCheckoutCone false
    mkdir -p "${repo_dir}/.git/info"
    printf '/*.sh\n' > "${repo_dir}/.git/info/sparse-checkout"
}

mkdir -p "$(dirname "${CACHE_DIR}")"

if [ -d "${CACHE_DIR}/.git" ]; then
    msg "updating ${SCRIPT_REPO} (${SCRIPT_REF})"
    git_sync -C "${CACHE_DIR}" remote set-url origin "${SCRIPT_REPO}"
    configure_sparse_checkout "${CACHE_DIR}"
    git_sync -C "${CACHE_DIR}" fetch --depth=1 --no-tags origin "${SCRIPT_REF}"
    git_sync -C "${CACHE_DIR}" checkout -q --detach FETCH_HEAD
    git_sync -C "${CACHE_DIR}" clean -fdx -q
else
    msg "cloning ${SCRIPT_REPO} (${SCRIPT_REF})"
    tmp_dir="${CACHE_DIR}.tmp.$$"
    rm -rf "${tmp_dir}"
    git_sync clone --depth=1 --filter=blob:none --no-tags --no-checkout "${SCRIPT_REPO}" "${tmp_dir}"
    configure_sparse_checkout "${tmp_dir}"
    git_sync -C "${tmp_dir}" fetch --depth=1 --no-tags origin "${SCRIPT_REF}"
    git_sync -C "${tmp_dir}" checkout -q --detach FETCH_HEAD
    rm -rf "${CACHE_DIR}"
    mv "${tmp_dir}" "${CACHE_DIR}"
    tmp_dir=""
fi

shopt -s nullglob
scripts=("${CACHE_DIR}"/*.sh)
shopt -u nullglob

if [ "${#scripts[@]}" -eq 0 ]; then
    echo "ERROR: no root-level .sh scripts found in ${SCRIPT_REPO} (${SCRIPT_REF})." >&2
    exit 1
fi

mkdir -p "${DEST_DIR}"
find "${DEST_DIR}" -maxdepth 1 -type f -name '*.sh' -delete
cp -f "${scripts[@]}" "${DEST_DIR}/"
chmod 0755 "${DEST_DIR}"/*.sh

msg "synced ${#scripts[@]} script(s) to ${DEST_DIR}"
