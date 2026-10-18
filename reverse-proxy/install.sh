#!/usr/bin/env bash
# Creates an unprivileged Debian 13 LXC running Caddy as a hostname-based reverse
# proxy that only accepts traffic from Cloudflare. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/reverse-proxy/install.sh)"
#
# Walks you through creating a Cloudflare Origin CA certificate and asks for
# anything not already set. For unattended runs, set these env vars:
#   ORIGIN_CERT, ORIGIN_KEY (paths to the PEM files), CTID, IP, GW
#   (plus the optional ones below)
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

# read_pem FILE "label" [secret] - reads one pasted PEM block from the terminal.
read_pem() {
    local file=$1 label=$2 secret=${3:-} line started=""
    local opts=()
    [[ -n $secret ]] && opts+=(-s)
    echo "Paste the ${bold}$label${reset} (from -----BEGIN to -----END), then press Enter:"
    : > "$file"
    while IFS= read -r "${opts[@]}" line </dev/tty; do
        # Trim surrounding whitespace and CRs that terminals add when pasting.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z $line ]] && continue
        [[ -z $started && $line != -----BEGIN* ]] && continue
        started=1
        printf '%s\n' "$line" >> "$file"
        [[ $line == -----END* ]] && break
    done
    if [[ -n $secret ]]; then echo "(received)"; fi
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found - is this a Proxmox host?"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

# --- Certificate -------------------------------------------------------------
if [[ -n ${ORIGIN_CERT:-} || -n ${ORIGIN_KEY:-} ]]; then
    [[ -f ${ORIGIN_CERT:-} && -f ${ORIGIN_KEY:-} ]] || die "ORIGIN_CERT and ORIGIN_KEY must both point to files"
    install -m 0600 "$ORIGIN_CERT" "$tmp/origin.pem"
    install -m 0600 "$ORIGIN_KEY" "$tmp/origin.key"
else
    cat <<EOF

${bold}Step 1/2: Cloudflare Origin CA certificate${reset}
Caddy presents this certificate to Cloudflare. It's free, lasts up to 15 years
and covers all your subdomains, so you only do this once.

  1. Open https://dash.cloudflare.com and select your domain.
  2. Go to SSL/TLS -> Origin Server -> Create Certificate.
  3. Keep "Generate private key and CSR with Cloudflare" and key type RSA (2048).
  4. Hostnames: keep both "*.yourdomain" and "yourdomain".
  5. Certificate Validity: 15 years. Click Create.
  6. Keep that page open. Cloudflare shows the private key only once.

EOF
    read_pem "$tmp/origin.pem" "Origin Certificate"
    echo
    read_pem "$tmp/origin.key" "Private Key (input is hidden)" secret
fi

openssl x509 -in "$tmp/origin.pem" -noout 2>/dev/null || die "that is not a valid certificate"
openssl pkey -in "$tmp/origin.key" -noout 2>/dev/null || die "that is not a valid private key"
[[ "$(openssl x509 -in "$tmp/origin.pem" -noout -pubkey)" == "$(openssl pkey -in "$tmp/origin.key" -pubout)" ]] \
    || die "the private key doesn't belong to the certificate"
openssl x509 -in "$tmp/origin.pem" -noout -checkend 0 >/dev/null || die "the certificate has expired"
if [[ "$(openssl x509 -in "$tmp/origin.pem" -noout -issuer)" != *"CloudFlare Origin"* ]]; then
    echo "warning: not issued by Cloudflare's Origin CA; Cloudflare will only accept it if it's publicly trusted" >&2
fi
cert_hosts="$(openssl x509 -in "$tmp/origin.pem" -noout -ext subjectAltName | grep -o 'DNS:[^,]*' | cut -d: -f2 | paste -sd' ')"
cert_until="$(openssl x509 -in "$tmp/origin.pem" -noout -enddate | cut -d= -f2)"
echo "Certificate OK: covers ${bold}$cert_hosts${reset}, valid until $cert_until"

# --- Container settings ------------------------------------------------------
echo
echo "${bold}Step 2/2: Container settings${reset}"
ask CTID "Container ID" "$(pvesh get /cluster/nextid)"
pct status "$CTID" &>/dev/null && die "container $CTID already exists"
ask IP "Container IP in CIDR form, or dhcp (static recommended for port forwarding)" "dhcp"
if [[ $IP != dhcp ]]; then
    ask GW "Gateway"
    [[ -n $GW ]] || die "a gateway is required for a static IP"
fi
echo

log "Fetching scripts from $REPO_RAW"
for f in setup.sh cloudflare-ips.sh proxy-site; do
    curl -fsSL "$REPO_RAW/reverse-proxy/$f" -o "$tmp/$f"
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
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
    --arch "$ARCH" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap 256 \
    --rootfs "$STORAGE:$DISK" \
    --net0 "$net" \
    --unprivileged 1 \
    --features nesting=1 \
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

log "Installing Caddy and firewall"
for f in setup.sh cloudflare-ips.sh proxy-site; do
    pct push "$CTID" "$tmp/$f" "/root/$f" --perms 0755
done
pct push "$CTID" "$tmp/origin.pem" /root/origin.pem --perms 0644
pct push "$CTID" "$tmp/origin.key" /root/origin.key --perms 0600
pct exec "$CTID" -- /root/setup.sh

ct_ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
cat <<EOF

==> Done. Container $CTID is at $ct_ip

${bold}Finish setup:${reset}
  1. Router: forward TCP 443 to $ct_ip (port 80 isn't needed).
  2. Cloudflare dashboard, for your domain:
     - DNS: an A record per hostname (or "*") pointing at your public IP, Proxied (orange cloud)
     - SSL/TLS -> Overview: encryption mode "Full (strict)"
     - SSL/TLS -> Origin Server: turn on "Authenticated Origin Pulls"
       (until you do, the proxy rejects every request)
  3. Add sites (hostnames must be covered by the certificate: $cert_hosts):
       pct exec $CTID -- proxy-site add app.example.com 192.168.1.50:8080
       pct exec $CTID -- proxy-site list
EOF
