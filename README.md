# proxmox-scripts

One-command installers for Proxmox VE, in the style of
[community-scripts](https://community-scripts.org/). Run them in the Proxmox host's shell as root.

| Script | What it creates |
|---|---|
| [reverse-proxy](reverse-proxy/) | Caddy reverse proxy LXC that routes by hostname, behind Cloudflare |

## Reverse proxy

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
```

Details in [reverse-proxy/README.md](reverse-proxy/README.md).
