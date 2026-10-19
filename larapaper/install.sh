#!/usr/bin/env bash
# Creates an unprivileged Debian 13 LXC running LaraPaper, a self-hosted server for
# TRMNL e-ink displays, in Docker. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/larapaper/install.sh)"
#
# Asks for anything not already set. For unattended runs, set these env vars:
#   CTID, IP, GW (plus the optional ones below)
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CT_HOSTNAME="${CT_HOSTNAME:-trmnl}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"                   # MiB; Chromium renders every screen
DISK="${DISK:-8}"                          # GiB
SSH_PUBKEY="${SSH_PUBKEY:-}"               # optional path to an authorized_keys file
PORT="${PORT:-80}"                         # port the device and browsers use
LARAPAPER_VERSION="${LARAPAPER_VERSION:-}" # release tag; empty = latest release

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
if [[ ! $PORT =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then die "invalid PORT: $PORT"; fi

# Docker in an unprivileged LXC broke with containerd.io 1.7.28-2 until Proxmox 9.1.
pve_ver="$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || true)"
if [[ -n $pve_ver && "$(printf '%s\n' "$pve_ver" 9.1 | sort -V | head -n1)" != 9.1 ]]; then
    echo "warning: Proxmox $pve_ver is older than 9.1; Docker containers may fail to start" \
        "in the LXC (sysctl ip_unprivileged_port_start: permission denied). Upgrading fixes it." >&2
fi

if [[ -z $LARAPAPER_VERSION ]]; then
    log "Looking up the latest LaraPaper release"
    LARAPAPER_VERSION="$(curl -fsSL https://api.github.com/repos/usetrmnl/larapaper/releases/latest \
        | grep -oP '"tag_name":\s*"\K[^"]+' || true)"
    [[ -n $LARAPAPER_VERSION ]] || die "couldn't look up the latest release; set LARAPAPER_VERSION (e.g. 0.45.0)"
fi
LARAPAPER_VERSION="${LARAPAPER_VERSION#v}"
echo "LaraPaper ${bold}$LARAPAPER_VERSION${reset}"

# --- Container settings ------------------------------------------------------
echo
echo "${bold}Container settings${reset}"
ask CTID "Container ID" "$(pvesh get /cluster/nextid)"
pct status "$CTID" &>/dev/null && die "container $CTID already exists"
cat <<EOF
The TRMNL device stores the server's address, so give the container a static IP
(or a DHCP reservation). If it changes, the device has to be set up again.
EOF
ask IP "Container IP in CIDR form, or dhcp" "dhcp"
if [[ $IP != dhcp ]]; then
    ask GW "Gateway"
    [[ -n $GW ]] || die "a gateway is required for a static IP"
fi
echo

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Fetching scripts from $REPO_RAW"
for f in setup.sh larapaper; do
    curl -fsSL "$REPO_RAW/larapaper/$f" -o "$tmp/$f"
done

ARCH="$(dpkg --print-architecture)"         # amd64, arm64, ...
log "Resolving latest Debian 13 template for $ARCH"
pveam update >/dev/null
# The list mixes architectures, so filter on ours before picking the newest.
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
# nesting + keyctl are what make Docker work in an unprivileged container.
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --arch "$ARCH" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "$STORAGE:$DISK" \
    --net0 "$net" \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    "${extra[@]}"

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

ct_ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
[[ -n $ct_ip ]] || die "container has no IP address"
url="http://$ct_ip"
[[ $PORT != 80 ]] && url+=":$PORT"

log "Installing Docker and LaraPaper"
for f in setup.sh larapaper; do
    pct push "$CTID" "$tmp/$f" "/root/$f" --perms 0755
done
pct exec "$CTID" -- env LARAPAPER_VERSION="$LARAPAPER_VERSION" PORT="$PORT" APP_URL="$url" \
    /root/setup.sh

cat <<EOF

==> Done. LaraPaper $LARAPAPER_VERSION is running at ${bold}$url${reset}

${bold}Finish setup:${reset}
  1. Open $url and register your account. Then turn off registration so nobody
     else on the network can sign up:
       pct exec $CTID -- larapaper registration off
  2. In LaraPaper, turn on "Permit Auto-Join" in the header.
  3. Set up the TRMNL device: connect to the "TRMNL" Wi-Fi network it opens, pick
     your Wi-Fi, choose Custom Server and enter:  $url   (no trailing slash)
     The device appears in LaraPaper's device list; turn auto-join off again.

  Update:  pct exec $CTID -- larapaper update [VERSION]
  Logs:    pct exec $CTID -- larapaper logs
EOF
