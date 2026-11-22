# proxmox-scripts

One-command installers for Proxmox VE, in the style of
[community-scripts](https://community-scripts.org/). Run them in the Proxmox host's shell as root.

| Script | What it creates |
|---|---|
| [reverse-proxy](reverse-proxy/) | Caddy reverse proxy LXC that routes by hostname, behind Cloudflare |
| [larapaper](larapaper/) | [LaraPaper](https://github.com/usetrmnl/larapaper) LXC: a self-hosted server for TRMNL e-ink displays |
| [host-backup](host-backup/) | Nightly backup of the host's own configuration (`/etc/pve`, mounts, network), for rebuilding after a disk failure |
| [es60w-scand](es60w-scand/) | Scan button on an Epson ES-60W (Wi-Fi) → PDF in Paperless-ngx's consume folder, no Windows needed |
| [course-watch](course-watch/) | LXC that checks the Sosnowiec marriage-course list every 6 hours and mails you about new courses and freed-up seats |
| [wedding](wedding/) | Caddy LXC serving the wedding website (directions, plan of the day, RSVP) behind the reverse proxy |

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

## ES-60W scan button → Paperless

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/es60w-scand/install.sh)"
```

Details in [es60w-scand/README.md](es60w-scand/README.md).

## Marriage course watcher

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/course-watch/install.sh)"
```

Details in [course-watch/README.md](course-watch/README.md).

## Wedding website

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/wedding/install.sh)"
```

Details in [wedding/README.md](wedding/README.md).
