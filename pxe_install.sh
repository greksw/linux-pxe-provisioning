#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

CONFIG_FILE="${1:-/etc/pxe-provisioning.conf}"
DNSMASQ_CONFIG="/etc/dnsmasq.d/pxe-provisioning.conf"
NGINX_CONFIG="/etc/nginx/conf.d/pxe-provisioning.conf"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || fatal 'Run this installer as root.'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

load_config() {
    [[ -r "${CONFIG_FILE}" ]] || fatal "Configuration file is not readable: ${CONFIG_FILE}"

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    : "${PXE_INTERFACE:?PXE_INTERFACE must be set}"
    : "${PXE_PROXY_ADDRESS:?PXE_PROXY_ADDRESS must be set}"
    : "${PXE_SERVER_ADDRESS:?PXE_SERVER_ADDRESS must be set}"
    : "${PXE_BASE_URL:?PXE_BASE_URL must be set}"
    : "${TFTP_ROOT:=/srv/pxe/tftp}"
    : "${HTTP_ROOT:=/srv/pxe/http}"
    : "${ALMA_VERSION:=9.8}"
    : "${ALMA_REPO_URL:=https://repo.almalinux.org/almalinux/${ALMA_VERSION}/BaseOS/x86_64/os/}"
    : "${ALMA_KICKSTART_URL:=}"
    : "${UBUNTU_VERSION:=24.04.5}"
    : "${UBUNTU_AUTOINSTALL_URL:=}"

    [[ "${PXE_BASE_URL}" =~ ^https?:// ]] || fatal 'PXE_BASE_URL must start with http:// or https://.'
    [[ "${PXE_SERVER_ADDRESS}" =~ ^[0-9a-fA-F:.]+$ ]] || fatal 'PXE_SERVER_ADDRESS must be an IP address.'
    ip link show "${PXE_INTERFACE}" >/dev/null 2>&1 || fatal "Network interface not found: ${PXE_INTERFACE}"
}

install_packages() {
    log 'Installing PXE service packages.'
    dnf install -y epel-release
    dnf install -y dnsmasq nginx ipxe-bootimgs python3
}

find_ipxe_image() {
    local filename=$1
    local result

    result=$(rpm -ql ipxe-bootimgs | awk -v wanted="/${filename}" '$0 ~ wanted "$" { print; exit }')
    [[ -n "${result}" && -f "${result}" ]] || fatal "Could not locate ${filename} in package ipxe-bootimgs."
    printf '%s\n' "${result}"
}

install_chainloaders() {
    local bios_image efi_image

    log 'Installing iPXE chainloaders.'
    bios_image=$(find_ipxe_image 'undionly.kpxe')
    efi_image=$(find_ipxe_image 'ipxe-snponly-x86_64.efi')

    install -d -m 0755 "${TFTP_ROOT}"
    install -m 0644 "${bios_image}" "${TFTP_ROOT}/undionly.kpxe"
    install -m 0644 "${efi_image}" "${TFTP_ROOT}/ipxe-snponly-x86_64.efi"
}

write_dnsmasq_config() {
    log 'Writing dnsmasq ProxyDHCP configuration.'

    cat > "${DNSMASQ_CONFIG}" <<EOF
# Managed by linux-pxe-provisioning.
# The existing DHCP server remains authoritative for address allocation.
port=0
interface=${PXE_INTERFACE}
bind-dynamic
log-dhcp

# ProxyDHCP: answer PXE clients without allocating addresses.
dhcp-range=${PXE_PROXY_ADDRESS},proxy

# Detect clients already running iPXE and hand them the HTTP menu.
dhcp-userclass=set:ipxe,iPXE
dhcp-boot=tag:ipxe,${PXE_BASE_URL}/boot.ipxe

# UEFI x86_64 client architecture values commonly used by PXE firmware.
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9

# Initial firmware chainloaders.
dhcp-boot=tag:!ipxe,tag:efi64,ipxe-snponly-x86_64.efi,,${PXE_SERVER_ADDRESS}
dhcp-boot=tag:!ipxe,tag:!efi64,undionly.kpxe,,${PXE_SERVER_ADDRESS}

enable-tftp
tftp-root=${TFTP_ROOT}
EOF

    dnsmasq --test
}

write_nginx_config() {
    log 'Writing nginx static boot-content configuration.'
    install -d -m 0755 "${HTTP_ROOT}"

    cat > "${NGINX_CONFIG}" <<EOF
# Managed by linux-pxe-provisioning.
server {
    listen 80;
    server_name _;
    root ${HTTP_ROOT};

    autoindex off;
    default_type application/octet-stream;

    location / {
        try_files \$uri =404;
    }
}
EOF

    nginx -t
}

render_boot_menu() {
    log 'Rendering iPXE boot menu.'

    PXE_BASE_URL="${PXE_BASE_URL}" \
    ALMA_VERSION="${ALMA_VERSION}" \
    ALMA_REPO_URL="${ALMA_REPO_URL}" \
    ALMA_KICKSTART_URL="${ALMA_KICKSTART_URL}" \
    UBUNTU_VERSION="${UBUNTU_VERSION}" \
    UBUNTU_AUTOINSTALL_URL="${UBUNTU_AUTOINSTALL_URL}" \
    HTTP_ROOT="${HTTP_ROOT}" \
    python3 - <<'PY'
import os
from pathlib import Path

base = os.environ["PXE_BASE_URL"].rstrip("/")
alma_version = os.environ["ALMA_VERSION"]
alma_repo = os.environ["ALMA_REPO_URL"]
alma_ks = os.environ.get("ALMA_KICKSTART_URL", "")
ubuntu_version = os.environ["UBUNTU_VERSION"]
ubuntu_ds = os.environ.get("UBUNTU_AUTOINSTALL_URL", "")
http_root = Path(os.environ["HTTP_ROOT"])

alma_extra = f" inst.ks={alma_ks}" if alma_ks else ""
ubuntu_extra = f" autoinstall ds=nocloud-net;s={ubuntu_ds}" if ubuntu_ds else ""

menu = f'''#!ipxe
set base {base}

:menu
menu Linux PXE Provisioning
item --gap -- ---------------- Linux installers ----------------
item alma AlmaLinux {alma_version}
item ubuntu Ubuntu Server {ubuntu_version} LTS
item shell iPXE shell
item reboot Reboot
choose --default shell --timeout 8000 target && goto ${{target}}

:alma
kernel ${{base}}/alma/{alma_version}/vmlinuz initrd=initrd.img ip=dhcp inst.repo={alma_repo}{alma_extra}
initrd ${{base}}/alma/{alma_version}/initrd.img
boot || goto failed

:ubuntu
kernel ${{base}}/ubuntu/{ubuntu_version}/vmlinuz initrd=initrd ip=dhcp url=${{base}}/ubuntu/{ubuntu_version}/ubuntu.iso{ubuntu_extra} ---
initrd ${{base}}/ubuntu/{ubuntu_version}/initrd
boot || goto failed

:shell
shell
goto menu

:reboot
reboot

:failed
echo Boot failed. Check media paths, HTTP reachability, and installer arguments.
shell
'''

http_root.mkdir(parents=True, exist_ok=True)
path = http_root / "boot.ipxe"
path.write_text(menu, encoding="utf-8")
path.chmod(0o644)
PY
}

validate_services() {
    log 'Enabling and validating services.'
    systemctl enable --now nginx
    systemctl enable --now dnsmasq
    systemctl restart nginx
    systemctl restart dnsmasq

    systemctl is-active --quiet nginx || fatal 'nginx is not active.'
    systemctl is-active --quiet dnsmasq || fatal 'dnsmasq is not active.'

    curl --fail --silent --show-error http://127.0.0.1/boot.ipxe >/dev/null
}

print_summary() {
    cat <<EOF

PXE provisioning service configured successfully.

Interface:      ${PXE_INTERFACE}
Server address: ${PXE_SERVER_ADDRESS}
TFTP root:      ${TFTP_ROOT}
HTTP root:      ${HTTP_ROOT}
Boot menu:      ${PXE_BASE_URL}/boot.ipxe

Next steps:
  1. Review firewalld/network ACLs for the provisioning VLAN.
  2. Publish AlmaLinux/Ubuntu media with scripts/prepare-media.sh.
  3. Test with a disposable BIOS and UEFI PXE client.

The installer did not modify firewall policy or the site's primary DHCP server.
EOF
}

main() {
    require_root
    require_command dnf
    require_command rpm
    require_command ip

    load_config
    install_packages
    require_command dnsmasq
    require_command nginx
    require_command curl

    install_chainloaders
    write_dnsmasq_config
    write_nginx_config
    render_boot_menu
    validate_services
    print_summary
}

main "$@"
