# LaraPaper LXC

An unprivileged Debian 13 container running [LaraPaper](https://github.com/usetrmnl/larapaper)
in Docker. LaraPaper is a self-hosted server for [TRMNL](https://trmnl.com) e-ink displays:
it renders screens (recipes, plugins, mashups, playlists) to images and serves them to the
devices, so a TRMNL or a DIY kit works without TRMNL's cloud.

```
TRMNL device ──HTTP (LAN)──► trmnl LXC ── Docker: LaraPaper + Chromium ──► the APIs your screens poll
browser (LAN) ─────────────►
```

## Install

In the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/larapaper/install.sh)"
```

It asks for the container ID and network settings, installs Docker, starts the latest
LaraPaper release and prints the URL. **Use a static IP or a DHCP reservation**: the device
stores the server's address, and LaraPaper puts it in every image URL it sends.

To run without prompts, set env vars:

| Variable | Default | |
|---|---|---|
| `CTID` | next free ID | |
| `IP`, `GW` | *(asked)* | `IP=192.168.1.30/24 GW=192.168.1.1`, or `IP=dhcp` |
| `CT_HOSTNAME` | `trmnl` | |
| `PORT` | `80` | port the device and browsers connect to |
| `LARAPAPER_VERSION` | latest release | e.g. `0.45.0` |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | |
| `BRIDGE` | `vmbr0` | |
| `CORES`, `MEMORY`, `DISK` | `2`, `2048` MiB, `8` GiB | Chromium renders every screen, so don't go much lower on memory |
| `SSH_PUBKEY` | *(none)* | path to an authorized_keys file on the host |
| `REPO_REF` | `main` | branch, tag or commit to install from |

Then:

1. Open the printed URL and register your account. Then turn registration off, so nobody
   else on the network can sign up:
   ```bash
   pct exec 130 -- larapaper registration off
   ```
2. In LaraPaper, turn on **Permit Auto-Join** in the header.
3. Set up the device. On first boot (or after a Wi-Fi reset) it opens a `TRMNL` Wi-Fi
   network. Connect to it, pick your Wi-Fi, choose **Custom Server** and enter the URL
   with no trailing slash. This needs firmware 1.4.6 or newer; flash a current one if
   the option is missing.
4. The device shows up in LaraPaper's device list. Turn auto-join off again.

## Managing it

From the Proxmox host (or inside the container without the `pct exec` part):

```bash
pct exec 130 -- larapaper update            # to the latest release
pct exec 130 -- larapaper update 0.45.0     # to a specific one (also for rolling back)
pct exec 130 -- larapaper registration on   # or off
pct exec 130 -- larapaper status
pct exec 130 -- larapaper logs
```

Check the [release notes](https://github.com/usetrmnl/larapaper/releases) before updating.
Some releases need a newer device firmware.

The compose project is in `/opt/larapaper`:

| File | |
|---|---|
| `compose.yml` | the service and its two volumes: the SQLite database and the generated images |
| `.env` | read by compose: image version and port |
| `larapaper.env` | the app's environment (`APP_KEY`, `APP_URL`, ...), readable by root only. Other [LaraPaper settings](https://github.com/usetrmnl/larapaper/blob/main/docs/docs/getting-started/environment-variables.md) go here; apply with `docker compose up -d` |

## Notes

- **Backups:** everything lives in the container (the Docker volumes and `/opt/larapaper`),
  so the regular Proxmox backup of the container covers it.
- **Changing the IP:** update `APP_URL` in `larapaper.env`, run `docker compose up -d`,
  then set the device up again with the new URL.
- **Exposing the web UI through the [reverse proxy](../reverse-proxy/):** possible, but the
  device should keep using the LAN address. LaraPaper builds image URLs from `APP_URL`, so
  pointing `APP_URL` at a public hostname would make the device download every image
  through Cloudflare.
- **Docker in an unprivileged LXC** needs the `nesting` and `keyctl` features, which the
  installer sets. On Proxmox older than 9.1, containers may fail to start with
  `sysctl net.ipv4.ip_unprivileged_port_start: permission denied`
  ([forum thread](https://forum.proxmox.com/threads/175437/)). Upgrading Proxmox fixes it.
- Screens load the TRMNL design framework's CSS and JS from `trmnl.com` when they render,
  so rendering needs internet access. Set `TRMNL_BLADE_FRAMEWORK_BASE_URL` to use a mirror.
