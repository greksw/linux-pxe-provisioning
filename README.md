# Linux PXE Provisioning

Portfolio-ready network boot toolkit for x86_64 Linux environments. The project keeps the site's existing DHCP server authoritative and adds a dedicated PXE service using **dnsmasq in ProxyDHCP mode**, **iPXE chainloading**, and **HTTP delivery** for boot assets.

The original repository history is intentionally preserved; the current implementation replaces the legacy single-script PXELINUX/ThinStation experiment with a safer and more maintainable architecture.

## Architecture

```text
Existing DHCP server
        |
        | IP address / gateway / DNS
        v
PXE client ----------------------+ 
        |                        |
        | PXE discovery          | HTTP boot assets
        v                        v
 dnsmasq ProxyDHCP          nginx static server
        |                        |
        | TFTP chainloader       +-- boot.ipxe
        v                        +-- alma/<version>/
   iPXE firmware                 +-- ubuntu/<version>/
        |
        +---- HTTP ----> kernel / initrd / ISO / kickstart / autoinstall
```

Only the small iPXE chainloader is delivered over TFTP. Large boot assets are delivered over HTTP.

## Target platform

- Server: AlmaLinux 9.x, x86_64
- DHCP model: existing DHCP server remains authoritative
- PXE service: dnsmasq ProxyDHCP
- Legacy BIOS chainloader: `undionly.kpxe`
- UEFI x86_64 chainloader: `ipxe-snponly-x86_64.efi`
- Boot content: nginx over HTTP
- Example operating systems:
  - AlmaLinux 9.8
  - Ubuntu Server 24.04.5 LTS

The OS versions are defaults in the example configuration, not hard-coded requirements.

## Repository structure

```text
.
├── README.md
├── pxe_install.sh
├── config/
│   └── pxe-provisioning.conf.example
├── scripts/
│   └── prepare-media.sh
├── templates/
│   └── boot.ipxe.template
└── .github/
    └── workflows/
        └── lint.yml
```

## Installation

```bash
git clone https://github.com/greksw/linux-pxe-provisioning.git
cd linux-pxe-provisioning

sudo install -m 0640 \
  config/pxe-provisioning.conf.example \
  /etc/pxe-provisioning.conf

sudo editor /etc/pxe-provisioning.conf
sudo ./pxe_install.sh /etc/pxe-provisioning.conf
```

The installer intentionally does **not**:

- replace the existing DHCP server;
- reset or rewrite the firewall;
- mount SMB/NFS shares;
- download operating-system ISO images automatically;
- create SSH keys;
- embed production IP addresses or credentials.

## Preparing boot media

The media helper requires a locally available ISO and an expected SHA-256 value. It verifies the ISO before publishing any files.

### AlmaLinux

```bash
sudo ./scripts/prepare-media.sh \
  --type alma \
  --version 9.8 \
  --iso /srv/iso/AlmaLinux-9.8-x86_64-boot.iso \
  --sha256 '<expected-sha256>' \
  --config /etc/pxe-provisioning.conf
```

### Ubuntu Server

```bash
sudo ./scripts/prepare-media.sh \
  --type ubuntu \
  --version 24.04.5 \
  --iso /srv/iso/ubuntu-24.04.5-live-server-amd64.iso \
  --sha256 '<expected-sha256>' \
  --config /etc/pxe-provisioning.conf
```

## Configuration model

`config/pxe-provisioning.conf.example` contains only documentation-safe example values. Site-specific values live outside Git, normally in `/etc/pxe-provisioning.conf`.

Important settings:

- `PXE_INTERFACE` — interface receiving PXE discovery traffic;
- `PXE_PROXY_ADDRESS` — network address/range used for ProxyDHCP matching;
- `PXE_SERVER_ADDRESS` — server address announced for TFTP;
- `PXE_BASE_URL` — HTTP URL reachable by booting clients;
- `TFTP_ROOT` — TFTP root;
- `HTTP_ROOT` — nginx document root;
- `ALMA_REPO_URL` — AlmaLinux installation source;
- `ALMA_KICKSTART_URL` — optional Kickstart file;
- `UBUNTU_AUTOINSTALL_URL` — optional NoCloud/autoinstall datasource.

## Security model

### Network impact

`dnsmasq` is configured in **proxy** mode. It supplies PXE boot information but does not allocate client IP addresses. This avoids competing with the site's existing DHCP server.

### Service exposure

The installer validates configuration but does not change `firewalld`. The operator must explicitly permit only the required traffic on the intended provisioning VLAN/interface:

- UDP/67 and UDP/4011 for PXE/ProxyDHCP;
- UDP/69 for TFTP chainloading;
- TCP/80 for boot assets.

Do not expose the PXE service to untrusted networks.

### Secrets

No passwords, SMB credentials, API tokens, or private keys belong in this repository. Kickstart/autoinstall files containing secrets should be stored separately and access-controlled.

### Image integrity

`prepare-media.sh` refuses to publish an ISO unless its SHA-256 matches the operator-supplied expected value. Obtain hashes from the distribution's official checksum source.

## Validation

```bash
sudo dnsmasq --test
sudo nginx -t
systemctl is-active dnsmasq nginx

curl -fsS http://127.0.0.1/boot.ipxe
ls -l /srv/pxe/tftp/
```

Expected chainloader files:

```text
undionly.kpxe
ipxe-snponly-x86_64.efi
```

Test first on an isolated provisioning VLAN or with a disposable VM configured for PXE boot.

## Operational notes

- BIOS and UEFI clients are handled separately.
- The HTTP boot menu is generated from the site configuration during installation.
- Boot-media preparation is separated from PXE-service installation so operating-system updates do not require reconfiguring dnsmasq.
- Distribution ISO layouts can change between releases; the media helper validates expected kernel/initrd paths before publishing content.
- Secure Boot is not configured by this project. Environments enforcing Secure Boot require a separately designed and tested signed boot chain.

## CI

GitHub Actions performs Bash syntax validation and ShellCheck static analysis. CI does not replace an end-to-end PXE boot test on real firmware/network hardware.

## Repository history

The repository preserves the original PXE automation history while the current implementation removes hard-coded infrastructure values, embedded credentials, unsafe CIFS modes, broad firewall modification, interactive `chroot` automation, and the PXELINUX-only boot flow.

The earlier companion `pxe_server2` experiment has been retired after consolidation into this repository.

## License

No license has been added yet. Add one only after deciding whether the repository should explicitly permit reuse beyond portfolio/reference purposes.
