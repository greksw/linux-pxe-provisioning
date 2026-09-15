#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

TYPE=""
VERSION=""
ISO_PATH=""
EXPECTED_SHA256=""
CONFIG_FILE="/etc/pxe-provisioning.conf"
MOUNT_DIR=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${MOUNT_DIR}" && -d "${MOUNT_DIR}" ]]; then
        if mountpoint -q "${MOUNT_DIR}"; then
            umount "${MOUNT_DIR}" || true
        fi
        rmdir "${MOUNT_DIR}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage:
  prepare-media.sh --type alma|ubuntu --version VERSION \
    --iso /path/to/image.iso --sha256 HASH \
    [--config /etc/pxe-provisioning.conf]
EOF
}

while (($#)); do
    case "$1" in
        --type)
            TYPE=${2:-}
            shift 2
            ;;
        --version)
            VERSION=${2:-}
            shift 2
            ;;
        --iso)
            ISO_PATH=${2:-}
            shift 2
            ;;
        --sha256)
            EXPECTED_SHA256=${2:-}
            shift 2
            ;;
        --config)
            CONFIG_FILE=${2:-}
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fatal "Unknown argument: $1"
            ;;
    esac
done

[[ ${EUID} -eq 0 ]] || fatal 'Run this script as root.'
[[ "${TYPE}" == "alma" || "${TYPE}" == "ubuntu" ]] || fatal '--type must be alma or ubuntu.'
[[ -n "${VERSION}" ]] || fatal '--version is required.'
[[ -f "${ISO_PATH}" ]] || fatal "ISO file not found: ${ISO_PATH}"
[[ "${EXPECTED_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || fatal '--sha256 must contain exactly 64 hexadecimal characters.'
[[ -r "${CONFIG_FILE}" ]] || fatal "Configuration file is not readable: ${CONFIG_FILE}"

# shellcheck disable=SC1090
source "${CONFIG_FILE}"
: "${HTTP_ROOT:=/srv/pxe/http}"

for command_name in sha256sum mount umount mountpoint install cp; do
    command -v "${command_name}" >/dev/null 2>&1 || fatal "Required command not found: ${command_name}"
done

actual_sha256=$(sha256sum "${ISO_PATH}" | awk '{print $1}')
if [[ "${actual_sha256,,}" != "${EXPECTED_SHA256,,}" ]]; then
    fatal "ISO checksum mismatch. Expected ${EXPECTED_SHA256}, got ${actual_sha256}."
fi

log "Checksum verified for ${ISO_PATH}."

MOUNT_DIR=$(mktemp -d /run/pxe-media.XXXXXX)
mount -o loop,ro "${ISO_PATH}" "${MOUNT_DIR}"

destination="${HTTP_ROOT}/${TYPE}/${VERSION}"
install -d -m 0755 "${destination}"

case "${TYPE}" in
    alma)
        kernel_path="${MOUNT_DIR}/images/pxeboot/vmlinuz"
        initrd_path="${MOUNT_DIR}/images/pxeboot/initrd.img"

        [[ -f "${kernel_path}" ]] || fatal "AlmaLinux kernel not found at expected path: ${kernel_path}"
        [[ -f "${initrd_path}" ]] || fatal "AlmaLinux initrd not found at expected path: ${initrd_path}"

        install -m 0644 "${kernel_path}" "${destination}/vmlinuz"
        install -m 0644 "${initrd_path}" "${destination}/initrd.img"
        ;;

    ubuntu)
        kernel_path="${MOUNT_DIR}/casper/vmlinuz"
        initrd_path="${MOUNT_DIR}/casper/initrd"

        [[ -f "${kernel_path}" ]] || fatal "Ubuntu kernel not found at expected path: ${kernel_path}"
        [[ -f "${initrd_path}" ]] || fatal "Ubuntu initrd not found at expected path: ${initrd_path}"

        install -m 0644 "${kernel_path}" "${destination}/vmlinuz"
        install -m 0644 "${initrd_path}" "${destination}/initrd"

        # Ubuntu live-server commonly retrieves the installation ISO over HTTP.
        install -m 0644 "${ISO_PATH}" "${destination}/ubuntu.iso"
        ;;
esac

log "Published ${TYPE} ${VERSION} boot media to ${destination}."
