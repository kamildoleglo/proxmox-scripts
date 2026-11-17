#!/usr/bin/env bash
# Creates a small unprivileged Debian 13 LXC that checks
# https://narzeczeni.sosnowiec.pl/kursy-przedmalzenskie/ every 6 hours and mails you when
# a new course appears or a full one gets free seats. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/course-watch/install.sh)"
#
# Mail goes out through an SMTP server. If Proxmox has an SMTP notification target, the
# installer offers to use the same server; otherwise it asks. For unattended runs set
# CTID, SMTP_HOST, MAIL_TO (plus SMTP_SECURITY, SMTP_PORT, SMTP_USER, SMTP_PASSWORD,
# MAIL_FROM as needed).
#
# Running it again finds the container (hostname course-watch) and updates the script,
# keeping the mail settings; RECONFIGURE=1 asks for them again.
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CT_HOSTNAME="${CT_HOSTNAME:-course-watch}"
STORAGE="${STORAGE:-local-lvm}"            # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                           # outbound only, so DHCP is fine
GW="${GW:-}"
MEMORY="${MEMORY:-256}"                    # MiB
DISK="${DISK:-2}"                          # GiB
SSH_PUBKEY="${SSH_PUBKEY:-}"               # optional path to an authorized_keys file
SCHEDULE="${SCHEDULE:-}"                   # systemd OnCalendar, default every 6 hours
URL="${URL:-}"
RECONFIGURE="${RECONFIGURE:-0}"
CONF=/etc/default/course-watch             # inside the container

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

# pve_cfg FILE SECTION KEY - values of KEY in "smtp: SECTION" of a Proxmox
# notifications.cfg, one per line (mailto can repeat).
pve_cfg() {
    [[ -r $1 ]] || return 0
    awk -v name="$2" -v key="$3" '
        /^[^ \t#][^:]*:/ { sec = ($1 == "smtp:" && $2 == name); next }
        sec && $1 == key { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); print }' "$1"
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pct >/dev/null || die "pct not found - is this a Proxmox host?"
if [[ -n $SCHEDULE ]]; then
    systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1 || die "SCHEDULE '$SCHEDULE' isn't a valid OnCalendar time"
fi

# --- Container ---------------------------------------------------------------------
if [[ -z ${CTID:-} ]]; then
    CTID="$(pct list | awk -v h="$CT_HOSTNAME" 'NR > 1 && $NF == h && !found++ {print $1}')"
fi
update=0
if [[ -n $CTID ]] && pct status "$CTID" &>/dev/null; then
    pct exec "$CTID" -- test -f "$CONF" 2>/dev/null \
        || die "container $CTID exists but isn't a running course-watch container"
    update=1
    echo "Updating course-watch in container ${bold}$CTID${reset}"
else
    echo "${bold}Container settings${reset}"
    ask CTID "Container ID" "$(pvesh get /cluster/nextid)"
fi

# --- Mail settings -----------------------------------------------------------------
if [[ $update == 0 || $RECONFIGURE == 1 ]]; then
    echo
    echo "${bold}Mail settings${reset}"
    if [[ -z ${SMTP_HOST:-} ]]; then
        cfg=/etc/pve/notifications.cfg priv=/etc/pve/priv/notifications.cfg
        for name in $(awk '$1 == "smtp:" {print $2}' "$cfg" 2>/dev/null); do
            [[ "$(pve_cfg "$cfg" "$name" disable)" == 1 ]] && continue
            server="$(pve_cfg "$cfg" "$name" server)"
            user="$(pve_cfg "$cfg" "$name" username)"
            ans=""
            read -rp "Send through ${server}${user:+ as $user}, like Proxmox's notification target '$name'? [Y/n]: " ans </dev/tty
            [[ $ans == [nN]* ]] && continue
            mode="$(pve_cfg "$cfg" "$name" mode)"
            SMTP_HOST="$server"
            SMTP_SECURITY="$([[ ${mode:-tls} == insecure ]] && echo none || echo "${mode:-tls}")"
            SMTP_PORT="$(pve_cfg "$cfg" "$name" port)"
            SMTP_USER="$user"
            SMTP_PASSWORD="$(pve_cfg "$priv" "$name" password)"
            MAIL_FROM="$(pve_cfg "$cfg" "$name" from-address)"
            # Its recipients: plain addresses plus the e-mail of each Proxmox user listed.
            to="$(pve_cfg "$cfg" "$name" mailto)"
            for u in $(pve_cfg "$cfg" "$name" mailto-user); do
                to+=$'\n'"$(awk -F: -v u="$u" '$1 == "user" && $2 == u {print $7}' /etc/pve/user.cfg)"
            done
            default_to="$(grep -v '^$' <<<"$to" | paste -sd, - || true)"
            break
        done
    fi
    if [[ -z ${SMTP_HOST:-} ]]; then
        echo "Mail goes out through an SMTP server, e.g. smtp.gmail.com with an app password."
        ask SMTP_HOST "SMTP server"
        [[ -n $SMTP_HOST ]] || die "an SMTP server is required"
        ask SMTP_SECURITY "Encryption: tls, starttls or none" "starttls"
        ask SMTP_PORT "Port" "$(case $SMTP_SECURITY in tls) echo 465;; starttls) echo 587;; *) echo 25;; esac)"
        ask SMTP_USER "Username (empty if the server needs none)" ""
        if [[ -n ${SMTP_USER:-} && -z ${SMTP_PASSWORD:-} ]]; then
            read -rsp "Password: " SMTP_PASSWORD </dev/tty; echo
        fi
        ask MAIL_FROM "Sender address" "${SMTP_USER:-}"
    fi
    [[ ${SMTP_SECURITY:=starttls} =~ ^(tls|starttls|none)$ ]] || die "SMTP_SECURITY must be tls, starttls or none"
    [[ -n ${MAIL_FROM:-${SMTP_USER:-}} ]] || die "a sender address (MAIL_FROM) is required"
    [[ -n ${default_to:-} ]] || default_to="$(awk -F: '$1 == "user" && $2 == "root@pam" {print $7}' /etc/pve/user.cfg 2>/dev/null || true)"
    ask MAIL_TO "Send the mails to (comma-separated)" "${default_to:-}"
    [[ $MAIL_TO == *@* ]] || die "MAIL_TO needs at least one e-mail address"
fi

# --- Prepare files -----------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log "Fetching course-watch from $REPO_RAW"
curl -fsSL "$REPO_RAW/course-watch/course-watch" -o "$tmp/course-watch"

if [[ $update == 1 ]]; then
    pct exec "$CTID" -- cat "$CONF" > "$tmp/old.conf"
    old() { sed -n "s/^$1=//p" "$tmp/old.conf" | tail -n1; }
    SCHEDULE="${SCHEDULE:-$(old SCHEDULE)}"
    URL="${URL:-$(old URL)}"
fi
SCHEDULE="${SCHEDULE:-*-*-* 00/6:00}"
URL="${URL:-https://narzeczeni.sosnowiec.pl/kursy-przedmalzenskie/}"

umask 077
if [[ $update == 0 || $RECONFIGURE == 1 ]]; then
    # Read by course-watch: KEY=value, value taken literally (no quoting).
    {
        echo "# course-watch settings. Re-run the installer to change the schedule."
        printf '%s=%s\n' URL "$URL" SCHEDULE "$SCHEDULE" MAIL_TO "$MAIL_TO" \
            SMTP_HOST "$SMTP_HOST" SMTP_SECURITY "$SMTP_SECURITY" SMTP_PORT "${SMTP_PORT:-}" \
            SMTP_USER "${SMTP_USER:-}" SMTP_PASSWORD "${SMTP_PASSWORD:-}" MAIL_FROM "${MAIL_FROM:-}"
    } > "$tmp/course-watch.conf"
else
    # Keep the mail settings, take the (possibly new) schedule and URL.
    grep -vE '^(URL|SCHEDULE)=' "$tmp/old.conf" > "$tmp/course-watch.conf" || true
    printf '%s=%s\n' URL "$URL" SCHEDULE "$SCHEDULE" >> "$tmp/course-watch.conf"
fi
umask 022

cat > "$tmp/course-watch.service" <<'EOF'
[Unit]
Description=Check the marriage course list for new courses and free seats
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/course-watch
StateDirectory=course-watch
EOF
cat > "$tmp/course-watch.timer" <<EOF
[Unit]
Description=Check the marriage course list every few hours

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
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
    [[ -n $GW ]] && net+=",gw=$GW"
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
        --description "course-watch: mails about new courses on $URL" \
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

    log "Installing Python"
    pct exec "$CTID" -- bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends python3 ca-certificates >/dev/null'
fi

# --- Install -----------------------------------------------------------------------
log "Installing course-watch"
pct push "$CTID" "$tmp/course-watch" /usr/local/bin/course-watch --perms 0755
pct push "$CTID" "$tmp/course-watch.conf" "$CONF" --perms 0600
pct push "$CTID" "$tmp/course-watch.service" /etc/systemd/system/course-watch.service --perms 0644
pct push "$CTID" "$tmp/course-watch.timer" /etc/systemd/system/course-watch.timer --perms 0644
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now course-watch.timer >/dev/null 2>&1

if [[ $update == 0 || $RECONFIGURE == 1 ]]; then
    # A new install's first check mails the current table; new settings get a test mail.
    log "Sending the first mail"
    if [[ $update == 1 ]]; then check=(course-watch --test); else check=(systemctl start course-watch.service); fi
    if ! pct exec "$CTID" -- "${check[@]}"; then
        pct exec "$CTID" -- journalctl -u course-watch.service -n 10 --no-pager -o cat 2>/dev/null || true
        die "the mail couldn't be sent. Fix the settings with:
  RECONFIGURE=1 CTID=$CTID bash -c \"\$(curl -fsSL $REPO_RAW/course-watch/install.sh)\"
or edit them with:  pct exec $CTID -- nano $CONF"
    fi
fi

cat <<EOF

==> Done. Container ${bold}$CTID${reset} checks $URL
    at $SCHEDULE and mails changes to $(sed -n 's/^MAIL_TO=//p' "$tmp/course-watch.conf").
EOF
if [[ $update == 0 ]]; then echo "    A first mail with the current table should be on its way."; fi
cat <<EOF

  Check now:      pct exec $CTID -- systemctl start course-watch
  Current table:  pct exec $CTID -- course-watch --list
  Test mail:      pct exec $CTID -- course-watch --test
  Logs:           pct exec $CTID -- journalctl -u course-watch
  Next run:       pct exec $CTID -- systemctl list-timers course-watch.timer
  Remove:         pct stop $CTID && pct destroy $CTID
EOF
