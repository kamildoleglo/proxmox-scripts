#!/usr/bin/env bash
# Creates an unprivileged Debian 13 LXC running Caddy as a hostname-based reverse
# proxy that only accepts traffic from Cloudflare. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
#
# Asks for anything not already set. For unattended runs, set these env vars:
#   CF_API_TOKEN, ACME_EMAIL, CTID, IP, GW  (plus the optional ones below)
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CT_HOSTNAME="${CT_HOSTNAME:-proxy}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-1}"
MEMORY="${MEMORY:-512}"                    # MiB
DISK="${DISK:-4}"                          # GiB
SSH_PUBKEY="${SSH_PUBKEY:-}"               # optional path to an authorized_keys file

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# ask VAR "prompt" [default] [secret] - prompts on the terminal unless VAR is already set.
ask() {
    local var=$1 prompt=$2 def=${3:-} secret=${4:-} ans
    [[ -n ${!var:-} ]] && return
    if [[ -n $secret ]]; then
        read -rsp "$prompt: " ans </dev/tty; echo
    else
        read -rp "$prompt${def:+ [$def]}: " ans </dev/tty
    fi
    printf -v "$var" '%s' "${ans:-$def}"
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found - is this a Proxmox host?"

ask CF_API_TOKEN "Cloudflare API token (Zone:DNS:Edit)" "" secret
[[ -n $CF_API_TOKEN ]] || die "a Cloudflare API token is required"
# Header goes through a file descriptor so the token never shows up in `ps`.
curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN") \
    https://api.cloudflare.com/client/v4/user/tokens/verify | grep -q '"status":"active"' \
    || die "Cloudflare rejected the API token"

ask ACME_EMAIL "Email for Let's Encrypt expiry notices"
[[ $ACME_EMAIL == *@*.* ]] || die "invalid email: $ACME_EMAIL"
ask CTID "Container ID" "$(pvesh get /cluster/nextid)"
pct status "$CTID" &>/dev/null && die "container $CTID already exists"
ask IP "Container IP in CIDR form, or dhcp (static recommended for port forwarding)" "dhcp"
if [[ $IP != dhcp ]]; then
    ask GW "Gateway"
    [[ -n $GW ]] || die "a gateway is required for a static IP"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log "Fetching scripts from $REPO_RAW"
for f in setup.sh cf-origin-firewall.sh proxy-site; do
    curl -fsSL "$REPO_RAW/reverse-proxy/$f" -o "$tmp/$f"
done
(umask 077; printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" > "$tmp/caddy.env")

log "Resolving latest Debian 13 template"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -V | tail -n1)"
[[ -n $TEMPLATE ]] || die "no debian-13-standard template available"
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
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 256 \
    --rootfs "$STORAGE:$DISK" \
    --net0 "$net" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 1 \
    "${extra[@]}"

log "Waiting for network"
for _ in {1..30}; do
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 1
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "container has no network/DNS"

log "Installing Caddy and firewall"
for f in setup.sh cf-origin-firewall.sh proxy-site; do
    pct push "$CTID" "$tmp/$f" "/root/$f" --perms 0755
done
pct push "$CTID" "$tmp/caddy.env" /root/caddy.env --perms 0600
pct exec "$CTID" -- env ACME_EMAIL="$ACME_EMAIL" /root/setup.sh

ct_ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
cat <<EOF

==> Done. Container $CTID is at $ct_ip

Next steps:
  1. Forward TCP 443 on your router to $ct_ip.
  2. In Cloudflare: proxied DNS records, SSL mode "Full (strict)",
     and Authenticated Origin Pulls turned on.
  3. Add sites:
       pct exec $CTID -- proxy-site add app.example.com 192.168.1.50:8080
       pct exec $CTID -- proxy-site list
EOF
