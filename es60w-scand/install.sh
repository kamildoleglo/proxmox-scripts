#!/usr/bin/env bash
# Installs es60w-scand into an existing container (typically the Paperless-ngx one):
# pressing the scan button on an Epson ES-60W (Wi-Fi) scans the feeder into a PDF
# in a folder such as Paperless's consume directory. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/es60w-scand/install.sh)"
#
# Asks for anything not already set. For unattended runs, set these env vars:
#   CTID, OUTPUT_DIR, SCANNER_IP (or SCANNER_MAC), plus the optional SCAN_* settings.
# Running it again updates the daemon and keeps the settings in /etc/es60w-scand.env.
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CONF=/etc/es60w-scand.env          # inside the container
APP_DIR=/opt/es60w-scand
UNIT=/etc/systemd/system/es60w-scand.service

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

# --- Container -----------------------------------------------------------------
# Suggest the running container that looks like Paperless.
default_ct="$(pct list | awk 'NR > 1 && $2 == "running" && tolower($NF) ~ /paperless/ {print $1; exit}')"
echo "${bold}Container${reset} (the one that has the folder the PDFs go to)"
ask CTID "Container ID" "$default_ct"
[[ $CTID =~ ^[0-9]+$ ]] || die "invalid container ID: $CTID"
[[ "$(pct status "$CTID" 2>/dev/null)" == *running* ]] || die "container $CTID isn't running"
ct() { pct exec "$CTID" -- "$@"; }

ct sh -c 'command -v systemctl >/dev/null' || die "container $CTID has no systemd"

# Settings from an earlier install become the defaults; env vars still win.
existing="$(ct cat "$CONF" 2>/dev/null || true)"
prev() { grep -oP "^$1=\K.*" <<<"$existing" | tail -n1 || true; }

# --- Output folder ---------------------------------------------------------------
# Suggest the earlier choice, else the consume dir of a community-scripts Paperless.
default_dir="$(prev OUTPUT_DIR)"
[[ -n $default_dir ]] || default_dir="$(ct sh -c 'grep -hoP "^PAPERLESS_CONSUMPTION_DIR=\K.*" /opt/paperless/paperless.conf 2>/dev/null' || true)"
ask OUTPUT_DIR "Folder for the scanned PDFs (Paperless consume dir)" "${default_dir:-/opt/paperless/consume}"
[[ $OUTPUT_DIR == /* && $OUTPUT_DIR != *[[:space:]]* ]] || die "OUTPUT_DIR must be an absolute path without spaces"
ct test -d "$OUTPUT_DIR" || die "$OUTPUT_DIR doesn't exist in container $CTID"

# --- Scanner -----------------------------------------------------------------------
# The daemon recognises the scanner by its MAC in the scanner's mDNS announcements,
# so it follows IP changes. The installer only needs the IP to look the MAC up.
# It never connects to the scanner's port 1865: the scanner serves one connection
# at a time and stray ones can wedge it.
echo
echo "${bold}Scanner${reset} (switch it on and let it join the Wi-Fi first)"
SCANNER_MAC="${SCANNER_MAC:-}"
if [[ -z $SCANNER_MAC ]]; then
    ask SCANNER_IP "Scanner IP (see your router or the Epson Smart Panel app)" "$(prev SCANNER_HOST)"
    [[ -n $SCANNER_IP ]] || die "the scanner's IP (or SCANNER_MAC) is required"
    ping -c 2 -W 2 "$SCANNER_IP" >/dev/null 2>&1 || true
    SCANNER_MAC="$(ip neigh show "$SCANNER_IP" | awk '/lladdr/ {print $5; exit}')"
    if [[ -n $SCANNER_MAC ]]; then
        echo "Scanner MAC: $SCANNER_MAC"
    else
        # Scanner asleep or on another subnet: reuse the earlier install's MAC, else ask.
        SCANNER_MAC="$(prev SCANNER_MAC)"
        ask SCANNER_MAC "Couldn't look up $SCANNER_IP's MAC; enter it (aa:bb:cc:dd:ee:ff)"
    fi
fi
SCANNER_MAC="${SCANNER_MAC,,}"
[[ $SCANNER_MAC =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "invalid MAC address: $SCANNER_MAC"
SCANNER_IP="${SCANNER_IP:-$(prev SCANNER_HOST)}"

# --- Settings ----------------------------------------------------------------------
# setting KEY DEFAULT - env var, else the earlier install's value, else DEFAULT.
setting() { local v="${!1:-}"; [[ -n $v ]] || v="$(prev "$1")"; echo "${v:-$2}"; }
FALLBACK_DIR="$(setting FALLBACK_DIR /var/lib/es60w-scand/unsent)"
SCAN_DPI="$(setting SCAN_DPI 300)"
SCAN_COLOR="$(setting SCAN_COLOR C024)"
SCAN_JPEG_Q="$(setting SCAN_JPEG_Q 85)"
SCAN_MAX_IN="$(setting SCAN_MAX_IN 14)"
SCAN_TONE="$(setting SCAN_TONE 1)"
SCAN_BLACK="$(setting SCAN_BLACK 35)"
SCAN_WHITE="$(setting SCAN_WHITE 225)"
SCAN_GAMMA="$(setting SCAN_GAMMA 1.15)"
SCAN_SHARPEN="$(setting SCAN_SHARPEN 1.2,80,3)"
[[ $SCAN_DPI =~ ^(200|300|400|600)$ ]] || die "SCAN_DPI must be 200, 300, 400 or 600"
[[ $SCAN_COLOR =~ ^(C024|M008|M001)$ ]] || die "SCAN_COLOR must be C024, M008 or M001"
[[ $FALLBACK_DIR == /* && $FALLBACK_DIR != *[[:space:]]* ]] || die "FALLBACK_DIR must be an absolute path without spaces"

# --- Install -----------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Fetching es60w-scand from $REPO_RAW"
curl -fsSL "$REPO_RAW/es60w-scand/es60w-scand" -o "$tmp/es60w-scand"

# Python 3.9+ runs the daemon; Pillow is only needed for sharpening.
if ! ct sh -c 'python3 -c "import sys; sys.exit(sys.version_info < (3, 9))"' 2>/dev/null; then
    log "Installing python3 in container $CTID"
    ct env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 sh -c 'apt-get update -qq && apt-get install -y -qq python3 >/dev/null'
fi
if [[ $SCAN_SHARPEN != 0 ]] && ! ct python3 -c 'import PIL' 2>/dev/null; then
    log "Installing python3-pil (for sharpening) in container $CTID"
    ct env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 sh -c 'apt-get update -qq && apt-get install -y -qq python3-pil >/dev/null'
fi

cat > "$tmp/es60w-scand.env" <<EOF
# Settings for es60w-scand. After editing: systemctl restart es60w-scand
# (re-running the installer keeps them). All options are described in
# https://github.com/kamildoleglo/proxmox-scripts/tree/main/es60w-scand
SCANNER_HOST=$SCANNER_IP
SCANNER_MAC=$SCANNER_MAC
OUTPUT_DIR=$OUTPUT_DIR
FALLBACK_DIR=$FALLBACK_DIR
# 200, 300, 400 or 600
SCAN_DPI=$SCAN_DPI
# C024 colour, M008 grey, M001 black & white
SCAN_COLOR=$SCAN_COLOR
SCAN_JPEG_Q=$SCAN_JPEG_Q
# maximum page length in inches (receipts can be longer; the scanner takes up to 72)
SCAN_MAX_IN=$SCAN_MAX_IN
# levels curve applied by the scanner: input <= black -> 0, >= white -> 255,
# gamma > 1 darkens midtones (crisper text); SCAN_TONE=0 turns it off
SCAN_TONE=$SCAN_TONE
SCAN_BLACK=$SCAN_BLACK
SCAN_WHITE=$SCAN_WHITE
SCAN_GAMMA=$SCAN_GAMMA
# unsharp mask "radius,percent,threshold" (needs python3-pil); 0 turns it off
SCAN_SHARPEN=$SCAN_SHARPEN
EOF

cat > "$tmp/es60w-scand.service" <<EOF
[Unit]
Description=Epson ES-60W scan button -> PDF in $OUTPUT_DIR
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
EnvironmentFile=$CONF
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 -I $APP_DIR/es60w-scand
Restart=always
RestartSec=15
StateDirectory=es60w-scand
ProtectSystem=strict
ReadWritePaths=$OUTPUT_DIR $FALLBACK_DIR
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

log "Installing into container $CTID"
ct mkdir -p "$APP_DIR" "$FALLBACK_DIR"
pct push "$CTID" "$tmp/es60w-scand" "$APP_DIR/es60w-scand" --perms 0755
pct push "$CTID" "$tmp/es60w-scand.env" "$CONF" --perms 0600
pct push "$CTID" "$tmp/es60w-scand.service" "$UNIT" --perms 0644
ct systemctl daemon-reload
ct systemctl enable es60w-scand >/dev/null 2>&1

# A restart stops the old daemon with SIGTERM, which releases the scanner session.
log "Starting es60w-scand"
since="$(ct date '+%Y-%m-%d %H:%M:%S')"
ct systemctl restart es60w-scand
# Some unprivileged containers can't set up the sandboxing (status 226/NAMESPACE);
# drop it there rather than not running at all.
sleep 2
if ct journalctl -u es60w-scand --since "$since" --no-pager -o cat | grep -q 'status=226/NAMESPACE'; then
    log "Container can't sandbox services; running es60w-scand without it"
    ct mkdir -p "$UNIT.d"
    printf '[Service]\nProtectSystem=no\nReadWritePaths=\nProtectHome=no\nPrivateTmp=no\n' \
        > "$tmp/nosandbox.conf"
    pct push "$CTID" "$tmp/nosandbox.conf" "$UNIT.d/no-sandbox.conf" --perms 0644
    ct systemctl daemon-reload
    since="$(ct date '+%Y-%m-%d %H:%M:%S')"
    ct systemctl restart es60w-scand
fi

state=""
for _ in {1..30}; do
    out="$(ct journalctl -u es60w-scand --since "$since" --no-pager -o cat)"
    if grep -q 'waiting for the scan button' <<<"$out"; then state=connected; break; fi
    if grep -q 'waiting for the scanner to come online' <<<"$out"; then state=waiting; break; fi
    sleep 1
done
ct systemctl is-active --quiet es60w-scand \
    || die "es60w-scand isn't running, see: pct exec $CTID -- journalctl -u es60w-scand -n 50"

echo
case $state in
    connected) echo "==> Done. es60w-scand is connected to the scanner." ;;
    waiting)   echo "==> Done. es60w-scand is running and waiting for the scanner to come online." ;;
    *)         echo "==> Done. es60w-scand is running; it hasn't reached the scanner yet (see the logs)." ;;
esac
cat <<EOF

  Load paper face down, top edge first, and press the scan button. Each press
  scans everything in the feeder into one PDF in ${bold}$OUTPUT_DIR${reset}.

  Logs:      pct exec $CTID -- journalctl -u es60w-scand -f
  Settings:  pct exec $CTID -- nano $CONF
             then: pct exec $CTID -- systemctl restart es60w-scand
  Update:    run this installer again

  Only one program can hold the scanner: while es60w-scand runs, Epson's apps
  (Epson Smart Panel, Epson ScanSmart) can't scan from it.
EOF
