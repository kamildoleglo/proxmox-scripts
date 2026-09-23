# Reverse proxy LXC

An unprivileged Debian 13 container running [Caddy](https://caddyserver.com/), routing
requests by hostname to machines on the home network. All traffic arrives through
Cloudflare's proxy, and the container is locked down so that **only Cloudflare** can
talk to it.

```
visitor ──► Cloudflare ──► router :443 ──► proxy LXC (Caddy) ──┬─► app1.example.com host
                                                               ├─► app2.example.com host
                                                               └─► ...
```

## Install

You'll need a Cloudflare API token: in *My Profile → API Tokens*, create one with
*Zone → DNS → Edit* on your domain. Then, in the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
```

It asks for the token, your email (for Let's Encrypt), the container ID and the network
settings. Use a static IP (or a DHCP reservation) so the port forward keeps working. To
run it without prompts, set the answers as env vars:

| Variable | Default | |
|---|---|---|
| `CF_API_TOKEN`, `ACME_EMAIL` | *(asked)* | |
| `CTID` | next free ID | |
| `IP`, `GW` | *(asked)* | `IP=192.168.1.20/24 GW=192.168.1.1`, or `IP=dhcp` |
| `CT_HOSTNAME` | `proxy` | |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | |
| `BRIDGE` | `vmbr0` | |
| `CORES`, `MEMORY`, `DISK` | `1`, `512` MiB, `4` GiB | |
| `SSH_PUBKEY` | *(none)* | path to an authorized_keys file on the host |
| `REPO_REF` | `main` | branch, tag or commit to install from |

Then:

1. **Router:** forward TCP 443 to the container. Port 80 isn't needed.
2. **Cloudflare dashboard** for the zone:
   - DNS: an `A` record per hostname (or a `*` wildcard) pointing at your public IP,
     **Proxied** (orange cloud).
   - *SSL/TLS → Overview*: encryption mode **Full (strict)**.
   - *SSL/TLS → Origin Server*: turn on **Authenticated Origin Pulls**. Caddy rejects
     requests without Cloudflare's client certificate, so every site needs this.
   - *SSL/TLS → Edge Certificates*: **Always Use HTTPS** on.

## Managing sites

From the Proxmox host (or inside the container without the `pct exec` part):

```bash
pct exec 120 -- proxy-site add app.example.com 192.168.1.50:8080
pct exec 120 -- proxy-site add pve.example.com https://192.168.1.2:8006 --insecure
pct exec 120 -- proxy-site list
pct exec 120 -- proxy-site rm app.example.com
```

`--insecure` is for backends with a self-signed HTTPS certificate, like the Proxmox UI.
Each change is validated before Caddy reloads (with no downtime) and rolled back if
it's invalid. Sites are plain Caddy files in `/etc/caddy/sites/`, so for anything
custom you can write one by hand. Start it with `import cloudflare_only`.

## How it's locked down

| Layer | What it does |
|---|---|
| nftables firewall in the LXC | Ports 80/443 accept only [Cloudflare's IP ranges](https://www.cloudflare.com/ips/), refreshed daily. Direct hits on your home IP are dropped. |
| Authenticated Origin Pulls | Caddy requires the TLS client certificate that Cloudflare presents, so a connection that isn't from Cloudflare fails the TLS handshake. |
| SSL mode *Full (strict)* | Cloudflare → origin traffic is encrypted and Cloudflare verifies Caddy's real Let's Encrypt certificate. |
| Real client IP | Caddy trusts `CF-Connecting-IP` from Cloudflare's ranges only, so logs and backends (`X-Forwarded-For`) see the visitor and not Cloudflare. |

Certificates come from Let's Encrypt via the Cloudflare DNS challenge, so port 80 never
has to be open. The API token lives only in the container, in `/etc/caddy/caddy.env`
(root-only).

## Notes

- Logs: `pct exec 120 -- journalctl -u caddy -f`.
  Firewall: `pct exec 120 -- nft list table inet cf_origin`.
- LAN clients also go through Cloudflare. Pointing local DNS at the container directly
  won't work, because they don't have the origin-pull certificate. Reach the backends
  by their LAN IPs instead.
- The `caddy` package is held in apt so upgrades don't drop the Cloudflare modules.
  Upgrade with `pct exec 120 -- caddy upgrade`.
- The zone-level origin-pull certificate is shared by all Cloudflare customers. For
  stronger isolation, upload your own client certificate in Cloudflare (per-hostname
  Authenticated Origin Pulls) and point `trust_pool` in `/etc/caddy/Caddyfile` at its CA.
- If the port forward on your router rewrites the source address (SNAT), the IP
  firewall can't tell Cloudflare apart from anyone else. Authenticated Origin Pulls
  still protects you, but check your router's port-forward settings.
