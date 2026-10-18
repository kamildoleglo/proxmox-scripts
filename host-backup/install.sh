#!/usr/bin/env bash
# Sets up a nightly backup of the Proxmox host's own configuration (/etc/pve, mounts,
# network, /root, ...) to one of your backup storages. Run on the Proxmox host as root:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/host-backup/install.sh)"
#
# Asks for the storage unless STORAGE is set. Optional: KEEP, SCHEDULE, REPO_REF.
# Running it again updates the script and settings.
set -euo pipefail

REPO_REF="${REPO_REF:-main}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/$REPO_REF}"

CONFIG=/etc/default/pve-host-backup
# When re-running, earlier settings become the defaults; env vars still win.
env_storage="${STORAGE:-}" env_keep="${KEEP:-}" env_schedule="${SCHEDULE:-}"
STORAGE="" KEEP="" SCHEDULE=""
# shellcheck source=/dev/null
[[ -r $CONFIG ]] && . "$CONFIG"
prev_storage="$STORAGE"
STORAGE="$env_storage"
KEEP="${env_keep:-${KEEP:-14}}"
SCHEDULE="${env_schedule:-${SCHEDULE:-*-*-* 04:00}}"   # systemd OnCalendar

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
command -v pvesm >/dev/null || die "pvesm not found - is this a Proxmox host?"
[[ $KEEP =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a positive number"

# --- Storage -----------------------------------------------------------------
backup_storages="$(pvesm status --content backup | awk 'NR > 1 && $3 == "active" {print $1}')"
[[ -n $backup_storages ]] || die "no active storage holds backups; add one under Datacenter -> Storage"
# Suggest the previous choice, else the storage the guest backup jobs already use.
default="$prev_storage"
[[ -n $default ]] || default="$(awk '$1 == "storage" {print $2; exit}' /etc/pve/jobs.cfg 2>/dev/null || true)"
[[ -n $default ]] || default="$(head -n1 <<<"$backup_storages")"

if [[ -z ${STORAGE:-} ]]; then
    echo "Storages that hold backups:"
    pvesm status --content backup
    echo
fi
ask STORAGE "Storage for the host backup" "$default"
grep -qx -- "$STORAGE" <<<"$backup_storages" || die "'$STORAGE' isn't an active storage with backup content"

type="$(pvesm status --storage "$STORAGE" | awk 'NR == 2 {print $2}')"
if [[ $type == dir ]]; then
    path="$(perl -MPVE::Storage -e 'print PVE::Storage::config()->{ids}{$ARGV[0]}{path}' "$STORAGE")"
    src="$(findmnt -no SOURCE -T "$path")" root_src="$(findmnt -no SOURCE -T /)"
    # ZFS datasets of one pool share its disks: compare pool names.
    [[ $(findmnt -no FSTYPE -T /) == zfs ]] && src=${src%%/*} root_src=${root_src%%/*}
    if [[ $src == "$root_src" ]]; then
        echo "${bold}warning:${reset} $STORAGE ($path) is on the same disk as Proxmox itself." >&2
        echo "         If that disk dies, the backup goes with it. Pick an NFS/SMB/PBS storage or another disk." >&2
        ans=""
        read -rp "Use it anyway? [y/N]: " ans </dev/tty
        [[ $ans == [yY]* ]] || exit 1
    fi
fi

# --- Install -----------------------------------------------------------------
# sqlite3 makes a consistent copy of the cluster database while it's in use.
if ! command -v sqlite3 >/dev/null; then
    log "Installing sqlite3"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sqlite3 >/dev/null
fi

log "Installing pve-host-backup from $REPO_RAW"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$REPO_RAW/host-backup/pve-host-backup" -o "$tmp"
install -m 0755 "$tmp" /usr/local/sbin/pve-host-backup

cat > "$CONFIG" <<EOF
# Settings for pve-host-backup. Re-run the installer to change them or the schedule.
STORAGE=$STORAGE
KEEP=$KEEP
SCHEDULE="$SCHEDULE"
EOF

cat > /etc/systemd/system/pve-host-backup.service <<'EOF'
[Unit]
Description=Back up the Proxmox host configuration
After=network-online.target pve-cluster.service pve-storage.target
Wants=network-online.target
OnFailure=pve-host-backup-failed.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pve-host-backup
Nice=10
IOSchedulingClass=idle
EOF
# Mail to root goes to the notification targets set up in Proxmox
# (Datacenter -> Notifications), same as failed vzdump jobs.
cat > /etc/systemd/system/pve-host-backup-failed.service <<'EOF'
[Unit]
Description=Report a failed Proxmox host configuration backup

[Service]
Type=oneshot
ExecStart=/bin/sh -c '{ printf "Subject: pve-host-backup failed on %H\n\n"; journalctl -u pve-host-backup.service -n 30 --no-pager; } | /usr/sbin/sendmail root'
EOF
cat > /etc/systemd/system/pve-host-backup.timer <<EOF
[Unit]
Description=Back up the Proxmox host configuration nightly

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now pve-host-backup.timer >/dev/null

log "Running the first backup"
systemctl start pve-host-backup.service || die "the backup failed, see: journalctl -u pve-host-backup -n 50"
journalctl -u pve-host-backup.service --since "-5min" --no-pager -o cat | grep '^==>' || true

cat <<EOF

==> Done. The host configuration is backed up to ${bold}$STORAGE${reset} at $SCHEDULE, keeping $KEEP.

  Run now:   systemctl start pve-host-backup
  Logs:      journalctl -u pve-host-backup
  Next run:  systemctl list-timers pve-host-backup.timer

Restoring after a disk failure:
  https://github.com/kamildoleglo/proxmox-scripts/tree/main/host-backup#restore
EOF
