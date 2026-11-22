# Wedding website

A one-page site for the guests: the ceremony and reception with **Wyznacz trasę**
buttons that open Google Maps navigation, the plan of the day, and RSVP contacts. It
uses the invitation's look: the same watercolour flowers (cut from the PDF), colours
and fonts.

The page is plain HTML and CSS in [`site/`](site/), with no build step. A tiny LXC runs
Caddy to serve it on port 80, behind the [reverse proxy](../reverse-proxy/).

## Install

In the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/wedding/install.sh)"
```

It creates an unprivileged Debian 13 container (`wedding`, 1 core, 256 MiB RAM, 2 GiB
disk, starts on boot) with Debian's Caddy package. Give it a static IP or a DHCP
reservation, because the proxy forwards to that address.

If it finds the reverse-proxy container (hostname `proxy`), it asks for a public
hostname, such as `slub.example.com`, and runs `proxy-site add` for you. The hostname
needs a DNS record in Cloudflare unless the wildcard `*` record covers it.

| Variable | Default | |
|---|---|---|
| `CTID` | *(asked)* | container ID |
| `IP`, `GW` | *(asked)*, `dhcp` | `IP=192.168.1.30/24 GW=192.168.1.1`, or `IP=dhcp` |
| `SITE_HOST` | *(asked)* | public hostname to add to the reverse proxy |
| `PROXY_CTID` | found by hostname `proxy` | reverse-proxy container |
| `SITE_SRC` | *(GitHub)* | local folder to take the site from instead of the repo |
| `STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | |
| `BRIDGE` | `vmbr0` | |
| `SSH_PUBKEY` | *(none)* | path to an authorized_keys file on the host |
| `REPO_REF` | `main` | branch, tag or commit to install from |

## Editing the page

Everything is in [`site/index.html`](site/index.html):

- **Plan dnia:** one `<li>` per item, shown in the order written (no sorting, so times
  after midnight stay at the end).
- **Phone numbers:** still placeholders (`000 000 000`). Change both the visible text
  and the `tel:` link.
- **Map links:** the `destination=` part of each Google Maps link is the place name
  as Maps knows it.

To see changes locally, run this from `wedding/site/` and open http://localhost:8000:

```bash
python3 -m http.server 8000
```

**Deploying a change:** re-run the installer. It finds the container and replaces only
the site files. By default it fetches them from GitHub, so push first. To deploy without
publishing, copy the folder to the host and run:

```bash
SITE_SRC=/root/site bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/wedding/install.sh)"
```

Browsers check for a new version on every visit, so guests see changes immediately.
If you add a file (such as a photo), also add it to `SITE_FILES` in `install.sh`.

## Notes

- The page and the server send `noindex`, so search engines leave it out. The link
  reaches guests only through the invitations, but anyone who has it can open the page.
- The fonts come from Google Fonts. Playfair Display and Montserrat are the same ones
  the invitation uses. Cormorant Garamond and Great Vibes stand in for Monterchi Serif
  and Lucien Schoenschrift, which aren't available as web fonts.
- Logs: `pct exec <CTID> -- journalctl -u caddy`. Remove: `pct stop <CTID> && pct destroy <CTID>`.
