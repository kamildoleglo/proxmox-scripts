#!/usr/bin/env bash
# Creates a tiny unprivileged Debian 13 LXC where Caddy serves the wedding website
# (wedding/site/) on port 80, and optionally adds it to the reverse proxy.
# Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/wedding/install.sh)"
#
# Running it again finds the container (hostname wedding) and only updates the site
# files, so after editing the page: push, then re-run. To deploy files that aren't on
# GitHub, copy the site folder to the host and point SITE_SRC at it.
#
# For unattended runs set CTID, IP (and GW for a static IP), plus SITE_HOST and
# PROXY_CTID to add the site to the reverse proxy.
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CT_HOSTNAME="${CT_HOSTNAME:-wedding}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
MEMORY="${MEMORY:-256}"                    # MiB
DISK="${DISK:-2}"                          # GiB
SSH_PUBKEY="${SSH_PUBKEY:-}"               # optional path to an authorized_keys file
SITE_SRC="${SITE_SRC:-}"                   # local folder with the site, instead of GitHub
SITE_HOST="${SITE_HOST:-}"                 # public hostname, e.g. slub.example.com
PROXY_HOSTNAME="${PROXY_HOSTNAME:-proxy}"  # hostname of the reverse-proxy container
WEBROOT=/var/www/wedding                   # inside the container

# Everything the page needs. Add new files here.
SITE_FILES=(index.html style.css flowers.webp)

bold=$'\e[1m' reset=$'\e[0m'
die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ask VAR "prompt" [default] - prompts on the terminal unless VAR is already set.
ask() {
    local var=$1 prompt=$2 def=${3:-} ans
    [[ -n ${!var:-} ]] && return
    read -rp "$prompt${def:+ [$def]}: " ans </dev/tty
    printf -v "$var" '%s' "${ans:-$def}"
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found - is this a Proxmox host?"

# --- Container ---------------------------------------------------------------------
if [[ -z ${CTID:-} ]]; then
    CTID="$(pct list | awk -v h="$CT_HOSTNAME" 'NR > 1 && $NF == h && !found++ {print $1}')"
fi
update=0
if [[ -n $CTID ]] && pct status "$CTID" &>/dev/null; then
    pct exec "$CTID" -- grep -q '^# wedding-site' /etc/caddy/Caddyfile 2>/dev/null \
        || die "container $CTID exists but isn't a running wedding-site container"
    update=1
    echo "Updating the wedding site in container ${bold}$CTID${reset}"
else
    echo "${bold}Container settings${reset}"
    ask CTID "Container ID" "$(pvesh get /cluster/nextid)"
    cat <<EOF
The reverse proxy forwards to this container's address, so give it a static IP
(or a DHCP reservation). If it changes, run proxy-site add again with the new one.
EOF
    ask IP "Container IP in CIDR form, or dhcp" "dhcp"
    if [[ $IP != dhcp ]]; then
        ask GW "Gateway"
        [[ -n $GW ]] || die "a gateway is required for a static IP"
    fi
fi

# --- Site files --------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/site"
if [[ -n $SITE_SRC ]]; then
    log "Taking the site from $SITE_SRC"
    for f in "${SITE_FILES[@]}"; do
        [[ -f $SITE_SRC/$f ]] || die "$SITE_SRC/$f not found"
        cp "$SITE_SRC/$f" "$tmp/site/$f"
    done
else
    log "Fetching the site from $REPO_RAW"
    for f in "${SITE_FILES[@]}"; do
        curl -fsSL "$REPO_RAW/wedding/site/$f" -o "$tmp/site/$f"
    done
fi

cat > "$tmp/Caddyfile" <<EOF
# wedding-site: managed by the wedding installer, overwritten when it runs.
# Plain HTTP on port 80; HTTPS is done by Cloudflare and the reverse proxy in front.
:80 {
	root * $WEBROOT
	encode zstd gzip
	file_server
	# The link is shared only through the invitations; keep it out of search engines.
	header X-Robots-Tag "noindex, nofollow"
	# Browsers check for a newer version on every visit, so schedule edits show at once.
	header Cache-Control "no-cache"
	header -Server
}
EOF

# --- Create the container ----------------------------------------------------------
if [[ $update == 0 ]]; then
    ARCH="$(dpkg --print-architecture)"
    log "Resolving latest Debian 13 template for $ARCH"
    pveam update >/dev/null
    TEMPLATE="$(pveam available --section system \
        | awk -v arch="$ARCH" '$2 ~ "^debian-13-standard_.*_" arch "\\.tar" {print $2}' | sort -V | tail -n1)"
    [[ -n $TEMPLATE ]] || die "no debian-13-standard template available for $ARCH"
    if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
        log "Downloading $TEMPLATE"
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    fi

    net="name=eth0,bridge=$BRIDGE,ip=$IP"
    [[ -n ${GW:-} ]] && net+=",gw=$GW"
    extra=()
    [[ -n $SSH_PUBKEY ]] && extra+=(--ssh-public-keys "$SSH_PUBKEY")

    log "Creating container $CTID ($CT_HOSTNAME)"
    pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
        --arch "$ARCH" \
        --hostname "$CT_HOSTNAME" \
        --cores 1 \
        --memory "$MEMORY" \
        --swap 256 \
        --rootfs "$STORAGE:$DISK" \
        --net0 "$net" \
        --timezone host \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --description "wedding: Caddy serving the wedding website on :80" \
        ${extra[@]+"${extra[@]}"}

    # Started separately: `pct create --start` exits 0 even when the start fails.
    log "Starting container $CTID"
    if ! pct start "$CTID" || [[ "$(pct status "$CTID")" != *running* ]]; then
        die "container $CTID failed to start.
  See why with:  pct start $CTID --debug
  Remove it with: pct destroy $CTID"
    fi

    log "Waiting for network"
    for _ in {1..30}; do
        pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
        sleep 1
    done
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "container has no network/DNS"

    log "Installing Caddy"
    pct exec "$CTID" -- bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends caddy curl >/dev/null'
fi

# --- Install -----------------------------------------------------------------------
# The new files go to a fresh folder that then replaces the old one, so visitors never
# get a half-updated page.
log "Installing the site"
pct exec "$CTID" -- bash -c "rm -rf $WEBROOT.new && mkdir -p $WEBROOT.new"
for f in "${SITE_FILES[@]}"; do
    pct push "$CTID" "$tmp/site/$f" "$WEBROOT.new/$f" --perms 0644
done
pct exec "$CTID" -- bash -c "chmod 755 $WEBROOT.new && rm -rf $WEBROOT.old \
    && { [[ ! -d $WEBROOT ]] || mv $WEBROOT $WEBROOT.old; } \
    && mv $WEBROOT.new $WEBROOT && rm -rf $WEBROOT.old"

pct push "$CTID" "$tmp/Caddyfile" /etc/caddy/Caddyfile --perms 0644
pct exec "$CTID" -- caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "the generated Caddyfile is invalid; see: pct exec $CTID -- caddy validate --config /etc/caddy/Caddyfile"
pct exec "$CTID" -- systemctl enable caddy >/dev/null 2>&1
pct exec "$CTID" -- systemctl reload-or-restart caddy

ct_ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
[[ -n $ct_ip ]] || die "container has no IP address"
code="$(pct exec "$CTID" -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || true)"
[[ $code == 200 ]] || die "Caddy answers $code instead of 200; see: pct exec $CTID -- journalctl -u caddy"

# --- Reverse proxy -----------------------------------------------------------------
proxied=""
if [[ $update == 0 || -n $SITE_HOST ]]; then
    if [[ -z ${PROXY_CTID:-} ]]; then
        PROXY_CTID="$(pct list | awk -v h="$PROXY_HOSTNAME" 'NR > 1 && $NF == h && !found++ {print $1}')"
    fi
    if [[ -n $PROXY_CTID ]] && pct exec "$PROXY_CTID" -- test -x /usr/local/bin/proxy-site 2>/dev/null; then
        echo
        ask SITE_HOST "Public hostname for the site, e.g. slub.example.com (empty to skip)" ""
        if [[ -n $SITE_HOST ]]; then
            log "Adding $SITE_HOST to the reverse proxy (container $PROXY_CTID)"
            pct exec "$PROXY_CTID" -- proxy-site add "$SITE_HOST" "$ct_ip:80"
            proxied="https://$SITE_HOST"
        fi
    elif [[ -n $SITE_HOST ]]; then
        die "no reverse-proxy container found to add $SITE_HOST to (set PROXY_CTID)"
    fi
fi

cat <<EOF

==> Done. Container ${bold}$CTID${reset} serves the wedding site at http://$ct_ip/
EOF
if [[ -n $proxied ]]; then echo "    and publicly at ${bold}$proxied${reset} (once its DNS record exists in Cloudflare)."; fi
if [[ ${IP:-} == dhcp ]]; then echo "    The IP came from DHCP: reserve it on your router so the proxy keeps finding it."; fi
cat <<EOF

  Update the site: re-run this installer (or with SITE_SRC=/path/to/site)
  Add to proxy:    pct exec <proxy CTID> -- proxy-site add <hostname> $ct_ip:80
  Logs:            pct exec $CTID -- journalctl -u caddy
  Remove:          pct stop $CTID && pct destroy $CTID
EOF
