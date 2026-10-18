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

In the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
```

The installer walks you through creating a **Cloudflare Origin CA certificate** in the
dashboard and pasting it in (the private key isn't shown on screen). It then asks for the
container ID and network settings. The certificate is checked before anything is
created: it must be valid, match its key and not be expired. Use a static IP or a DHCP
reservation so the port forward keeps working.

To run without prompts, save the certificate and key as files and set env vars:

| Variable | Default | |
|---|---|---|
| `ORIGIN_CERT`, `ORIGIN_KEY` | *(asked)* | paths to the Origin certificate and private key (PEM) |
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

- `--insecure` is for backends with a self-signed HTTPS certificate, like the Proxmox UI.
- The hostname must be covered by the Origin certificate. The default `*.example.com` +
  `example.com` covers the domain and one level of subdomains, not `a.b.example.com`.
- Each change is validated before Caddy reloads (with no downtime) and rolled back if
  it's invalid.
- Sites are plain Caddy files in `/etc/caddy/sites/`, so for anything custom you can
  write one by hand. Start it with `import cloudflare_only`.

## How it's locked down

| Layer | What it does |
|---|---|
| nftables firewall in the LXC | Ports 80/443 accept only [Cloudflare's IP ranges](https://www.cloudflare.com/ips/), refreshed daily. Direct hits on your home IP are dropped. |
| Authenticated Origin Pulls | Caddy requires the TLS client certificate that Cloudflare presents, so a connection that isn't from Cloudflare fails the TLS handshake. |
| SSL mode *Full (strict)* + Origin CA certificate | Cloudflare → origin traffic is encrypted, and Cloudflare verifies the certificate it issued to you. |
| Real client IP | Caddy trusts `CF-Connecting-IP` only from Cloudflare's ranges and passes the visitor's IP to backends in `X-Forwarded-For` and `X-Real-IP`. |

No secrets for Cloudflare's API are stored anywhere. The only sensitive file is the
Origin certificate's private key, `/etc/caddy/origin.key`, readable only by root and
Caddy.

## Notes

- Logs: `pct exec 120 -- journalctl -u caddy -f`.
  Firewall: `pct exec 120 -- nft list table inet cf_origin`.
- Caddy is the stock package from Caddy's apt repository and updates with the rest of
  the system (`apt upgrade`).
- The Origin certificate is trusted only by Cloudflare. If you switch a hostname to
  *DNS only* (grey cloud), browsers will show certificate errors for it.
- LAN clients also go through Cloudflare. Pointing local DNS at the container directly
  won't work, because they have neither a trusted certificate nor the origin-pull
  client certificate. Reach the backends by their LAN IPs instead.
- **Replacing the certificate** (another domain, or after it expires): create a new one
  in Cloudflare covering every hostname you need, then:
  ```bash
  pct push 120 origin.pem /etc/caddy/origin.pem --perms 0644
  pct push 120 origin.key /root/origin.key --perms 0600
  pct exec 120 -- install -m 0640 -g caddy /root/origin.key /etc/caddy/origin.key
  pct exec 120 -- rm /root/origin.key
  pct exec 120 -- systemctl reload caddy
  ```
- The zone-level origin-pull certificate is shared by all Cloudflare customers. For
  stronger isolation, upload your own client certificate in Cloudflare (per-hostname
  Authenticated Origin Pulls) and point `trust_pool` in `/etc/caddy/Caddyfile` at its CA.
- If the port forward on your router rewrites the source address (SNAT), the IP
  firewall can't tell Cloudflare apart from anyone else. Authenticated Origin Pulls
  still protects you, but check your router's port-forward settings.
