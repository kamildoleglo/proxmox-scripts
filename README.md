# proxmox-scripts

One-command installers for Proxmox VE, in the style of
[community-scripts](https://community-scripts.org/). Run them in the Proxmox host's shell as root.

| Script | What it creates |
|---|---|
| [reverse-proxy](reverse-proxy/) | Caddy reverse proxy LXC that routes by hostname, behind Cloudflare |
| [larapaper](larapaper/) | [LaraPaper](https://github.com/usetrmnl/larapaper) LXC: a self-hosted server for TRMNL e-ink displays |
| [host-backup](host-backup/) | Nightly backup of the host's own configuration (`/etc/pve`, mounts, network), for rebuilding after a disk failure |

## Reverse proxy

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
```

Details in [reverse-proxy/README.md](reverse-proxy/README.md).

## LaraPaper (TRMNL server)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/larapaper/install.sh)"
```

Details in [larapaper/README.md](larapaper/README.md).

## Host configuration backup

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/host-backup/install.sh)"
```

Details and restore steps in [host-backup/README.md](host-backup/README.md).
