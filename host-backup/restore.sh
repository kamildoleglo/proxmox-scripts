#!/usr/bin/env bash
# Rebuilds a Proxmox host from a pve-host-backup backup after a reinstall. Run on the
# freshly installed host as root, once the storage holding the backup is added back
# (Datacenter -> Storage -> Add):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/host-backup/restore.sh)"
#
# Takes the newest backup of this host, shows what each step would change and asks
# before doing it. Optional env vars:
#   SOURCE           storage ID holding the backup, or the path of a .tar.zst (asked)
#   RESTORE_STORAGE  storage for the guest disks, if their old one doesn't exist anymore
#   YES=1            answer yes to every question
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive

SOURCE="${SOURCE:-${1:-}}"
RESTORE_STORAGE="${RESTORE_STORAGE:-}"
YES="${YES:-}"

bold=$'\e[1m' reset=$'\e[0m'
die()  { echo "error: $*" >&2; exit 1; }
log()  { echo "==> $*"; }
warn() { echo "${bold}warning:${reset} $*" >&2; }
step() { echo; echo "${bold}### $*${reset}"; }

# ask VAR "prompt" [default] - prompts on the terminal unless VAR is already set.
ask() {
    local var=$1 prompt=$2 def=${3:-} ans
    [[ -n ${!var:-} ]] && return
    read -rp "$prompt${def:+ [$def]}: " ans </dev/tty
    printf -v "$var" '%s' "${ans:-$def}"
}

# confirm "question" - yes/no on the terminal; YES=1 answers yes.
confirm() {
    local ans
    [[ -n $YES ]] && { echo "$1 yes (YES=1)"; return 0; }
    read -rp "$1 [y/N]: " ans </dev/tty
    [[ $ans == [yY]* ]]
}

[[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
command -v pvesm >/dev/null || die "pvesm not found - is this a Proxmox host?"

host="$(hostname)"
node="$host"
work="$(mktemp -d /root/pve-host-restore.XXXXXX)"
chmod 700 "$work"
exec > >(tee -a "$work/restore.log") 2>&1
done_steps=() skipped_steps=() todo=()

# --- Storage helpers (same as pve-host-backup) -------------------------------
declare -A S=()
load_storage() {
    local k v
    S=()
    while IFS='=' read -r k v; do
        S[$k]=$v
    done < <(perl -MPVE::Storage -e '
        my $s = PVE::Storage::config()->{ids}{$ARGV[0]} or exit;
        print "$_=$s->{$_}\n" for grep { !ref $s->{$_} } sort keys %$s;
    ' "$1")
    [[ -n ${S[type]:-} ]]
}

pbs_opts=() pbs_crypt=()
pbs_env() {
    local server=${S[server]} id=$1 priv=/etc/pve/priv/storage
    [[ $server == *:* ]] && server="[$server]"
    export PBS_REPOSITORY="${S[username]}@$server:${S[port]:-8007}:${S[datastore]}"
    PBS_PASSWORD="$(< "$priv/$id.pw")" || die "no password for storage '$id'"
    export PBS_PASSWORD
    [[ -n ${S[fingerprint]:-} ]] && export PBS_FINGERPRINT=${S[fingerprint]}
    [[ -n ${S[namespace]:-} ]] && pbs_opts=(--ns "${S[namespace]}")
    [[ -f $priv/$id.enc ]] && pbs_crypt=(--keyfile "$priv/$id.enc")
    return 0
}

# --- Get the backup ----------------------------------------------------------
if [[ -z $SOURCE ]]; then
    echo "Storages that hold backups:"
    pvesm status --content backup
    echo
    default="$(pvesm status --content backup | awk 'NR > 1 && $3 == "active" && $1 != "local" {print $1; exit}')"
    ask SOURCE "Storage with the host backup, or the path of a .tar.zst" "$default"
fi

archive=""
if [[ -f $SOURCE ]]; then
    archive="$SOURCE"
elif load_storage "$SOURCE"; then
    if [[ ${S[type]} == pbs ]]; then
        pbs_env "$SOURCE"
        t="$(proxmox-backup-client snapshot list "host/$host" "${pbs_opts[@]}" --output-format json \
            | perl -MJSON::PP -e '
                my ($t) = sort { $b <=> $a } map { $_->{"backup-time"} } @{ decode_json(join "", <STDIN>) };
                print $t // "";')" || true
        [[ -n $t ]] || die "no backup group host/$host on $SOURCE (is this host named like the old one?)"
        snap="host/$host/$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ)"
        log "Downloading $snap from $SOURCE"
        for a in meta:pve-host-backup etc:etc etc-pve:etc/pve root:root usr-local:usr/local \
                 var-spool-cron:var/spool/cron usr-share-keyrings:usr/share/keyrings; do
            name=${a%%:*} dest="$work/${a#*:}"
            if ! proxmox-backup-client restore "$snap" "$name.pxar" "$dest" --allow-existing-dirs \
                    "${pbs_opts[@]}" "${pbs_crypt[@]}"; then
                [[ $name == meta || $name == etc ]] && die "can't restore $name.pxar"
                warn "$name.pxar not restored (missing from older backups)"
            fi
        done
    else
        dir="$(perl -MPVE::Storage -e '
            my $cfg = PVE::Storage::config();
            PVE::Storage::activate_storage($cfg, $ARGV[0]);
            print PVE::Storage::get_backup_dir($cfg, $ARGV[0]);
        ' "$SOURCE")" || die "can't read backups from storage '$SOURCE'"
        shopt -s nullglob
        files=("$dir/pve-host-$host-"*.tar.zst)
        others=("$dir/pve-host-"*.tar.zst)
        shopt -u nullglob
        if (( ${#files[@]} == 0 )); then
            names="$(printf '%s\n' "${others[@]}" \
                | sed -nE 's#.*/pve-host-(.+)-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.tar\.zst$#\1#p' \
                | sort -u | paste -sd' ')"
            die "no backup of '$host' in $dir${names:+. Found backups of: $names. Reinstall with that hostname, it has to match.}"
        fi
        archive="${files[-1]}"      # names sort by date
    fi
else
    die "'$SOURCE' is neither a file nor a storage ID"
fi
if [[ -n $archive ]]; then
    log "Extracting $archive"
    tar --zstd -xpf "$archive" -C "$work"
fi

meta="$work/pve-host-backup"
B="$work"                                   # the backup's root, i.e. $B/etc/fstab
[[ -f $meta/config.db ]] || die "$SOURCE doesn't look like a pve-host-backup backup"
backup_host="$(cut -d. -f1 "$meta/info/hostname")"
[[ $backup_host == "$host" ]] \
    || die "the backup is of '$backup_host' but this host is '$host'. Reinstall with hostname $backup_host."

echo
echo "${bold}Restoring from:${reset} $(head -n1 "$meta/RESTORE.txt")"
echo "Everything extracted is in $work (the log too)."

pve_major() { awk -F'[ :.]+' '/^proxmox-ve:/ {print $2; exit}'; }
old_major="$(pve_major < "$meta/info/pveversion")"
new_major="$(pveversion -v | pve_major)"
[[ $old_major == "$new_major" ]] \
    || warn "the backup is from Proxmox VE $old_major, this is $new_major. Apt repositories won't be restored."

shopt -s nullglob
fresh_guests=(/etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf)
shopt -u nullglob
if (( ${#fresh_guests[@]} > 0 )); then
    warn "this host already has ${#fresh_guests[@]} VMs/containers; restoring is meant for a fresh install."
    confirm "Continue anyway?" || exit 1
fi

# --- 1. /etc/pve -------------------------------------------------------------
step "1/8 Proxmox configuration (/etc/pve)"
echo "Storages, backup jobs, users and permissions, firewall, notifications, guest configs."
if [[ -f $B/etc/pve/corosync.conf ]]; then
    warn "the backup is from a cluster node. Join this host to the cluster instead; skipping."
    skipped_steps+=("Proxmox configuration (cluster node: join the cluster)")
else
    echo "Storages in the backup:"
    grep -E '^[a-z]+: ' "$B/etc/pve/storage.cfg" | sed 's/^/  /' || true
    if confirm "Replace this host's Proxmox configuration with the backup?"; then
        cp -a /var/lib/pve-cluster/config.db "$work/config.db.fresh-install"
        systemctl stop pve-cluster
        install -m 0600 "$meta/config.db" /var/lib/pve-cluster/config.db
        rm -f /var/lib/pve-cluster/config.db-wal /var/lib/pve-cluster/config.db-shm
        systemctl start pve-cluster
        systemctl restart pvedaemon pveproxy pvestatd pvescheduler
        pvecm updatecerts >/dev/null 2>&1 || true
        log "Storages now (network shares get mounted on first use):"
        timeout 120 pvesm status || warn "some storages didn't respond"
        done_steps+=("Proxmox configuration")
    else
        skipped_steps+=("Proxmox configuration")
    fi
fi

# --- 2. Files ----------------------------------------------------------------
step "2/8 Files: /root, /usr/local, crontabs, SSH keys"
echo "Files that already exist are kept, except root's and the host's SSH keys, which"
echo "must match the restored configuration (and what other machines already trust)."
if confirm "Restore them?"; then
    paths=()
    for p in root usr/local var/spool/cron; do [[ -e $B/$p ]] && paths+=("$p"); done
    keys=()
    [[ -d $B/root/.ssh ]] && keys+=(root/.ssh)
    for k in "$B"/etc/ssh/ssh_host_*; do [[ -e $k ]] && keys+=("${k#"$B"/}"); done
    (( ${#keys[@]} )) && tar -C "$B" -cf - "${keys[@]}" | tar -C / -xpf - --overwrite
    (( ${#paths[@]} )) && tar -C "$B" -cf - "${paths[@]}" | tar -C / -xpf - --skip-old-files
    if [[ -f $B/etc/default/pve-host-backup && ! -e /etc/default/pve-host-backup ]]; then
        cp -a "$B/etc/default/pve-host-backup" /etc/default/
    fi
    systemctl reload ssh 2>/dev/null || true
    done_steps+=("Files and SSH keys")
else
    skipped_steps+=("Files and SSH keys")
fi

# --- 3. subuid/subgid --------------------------------------------------------
step "3/8 ID mappings for unprivileged containers (/etc/subuid, /etc/subgid)"
declare -A idmap_add=()
for f in subuid subgid; do
    [[ -f $B/etc/$f ]] || continue
    idmap_add[$f]="$(grep -vxFf "/etc/$f" "$B/etc/$f" || true)"
done
if [[ -z ${idmap_add[subuid]:-}${idmap_add[subgid]:-} ]]; then
    echo "Nothing to add."
else
    for f in subuid subgid; do
        [[ -n ${idmap_add[$f]:-} ]] && printf '  %s: %s\n' "$f" "${idmap_add[$f]//$'\n'/ }"
    done
    if confirm "Add these lines?"; then
        for f in subuid subgid; do
            [[ -n ${idmap_add[$f]:-} ]] && printf '%s\n' "${idmap_add[$f]}" >> "/etc/$f"
        done
        done_steps+=("subuid/subgid")
    else
        skipped_steps+=("subuid/subgid")
    fi
fi

# --- 4. Apt repositories and packages ----------------------------------------
step "4/8 Apt repositories and packages you installed"
restore_repos=""
if [[ $old_major == "$new_major" ]]; then
    restore_repos=1
    echo "Repositories (current files are saved to $work/apt-fresh-install.tar):"
    for f in "$B"/etc/apt/sources.list "$B"/etc/apt/sources.list.d/* "$B"/etc/apt/keyrings/* \
             "$B"/etc/apt/trusted.gpg.d/* "$B"/etc/apt/preferences.d/* "$B"/etc/apt/auth.conf.d/*; do
        [[ -f $f ]] || continue
        cmp -s "$f" "/${f#"$B"/}" || echo "  /${f#"$B"/}"
    done
fi
# Old kernels aren't worth reinstalling; the new install has a newer one.
mapfile -t pkgs < <(comm -23 <(sort -u "$meta/info/packages-manual") <(apt-mark showmanual | sort -u) \
    | grep -vE '^(proxmox-kernel|pve-kernel|linux-image|linux-headers|proxmox-headers|pve-headers)-[0-9]' || true)
echo "Packages: ${pkgs[*]:-(none)}"
if confirm "Restore the repositories and install these packages?"; then
    if [[ -n $restore_repos ]]; then
        tar -C / -cf "$work/apt-fresh-install.tar" etc/apt
        apt_paths=()
        for p in sources.list sources.list.d keyrings trusted.gpg.d preferences.d auth.conf.d; do
            [[ -e $B/etc/apt/$p ]] && apt_paths+=("etc/apt/$p")
        done
        (( ${#apt_paths[@]} )) && tar -C "$B" -cf - "${apt_paths[@]}" | tar -C / -xpf - --overwrite
        [[ -d $B/usr/share/keyrings ]] && tar -C "$B" -cf - usr/share/keyrings | tar -C / -xpf - --skip-old-files
    fi
    apt-get update || warn "apt-get update reported errors, see above"
    if (( ${#pkgs[@]} )) && ! apt-get install -y "${pkgs[@]}"; then
        failed=()
        for p in "${pkgs[@]}"; do apt-get install -y "$p" >/dev/null 2>&1 || failed+=("$p"); done
        (( ${#failed[@]} )) && todo+=("Packages that failed to install: ${failed[*]}")
    fi
    done_steps+=("Apt repositories and packages")
else
    skipped_steps+=("Apt repositories and packages")
fi

# --- 5. Mounts and systemd units ---------------------------------------------
step "5/8 Mounts outside Proxmox (fstab, systemd units) and other custom units"
declare -A have=()
while read -r src mnt _; do
    [[ -z ${src:-} || $src == \#* || -z ${mnt:-} ]] || have[$mnt]=1
done < /etc/fstab
fstab_add=() fstab_skip=()
while IFS= read -r line; do
    read -r src mnt type _ <<<"$line" || true
    [[ -z ${src:-} || $src == \#* || -z ${mnt:-} || ${type:-} == swap ]] && continue
    [[ -n ${have[$mnt]:-} ]] && continue
    # Disks that died with the old system are skipped; ones that survived are kept.
    case $src in
        UUID=*)     blkid -U "${src#UUID=}" >/dev/null ;;
        LABEL=*)    blkid -L "${src#LABEL=}" >/dev/null ;;
        PARTUUID=*) [[ -n $(blkid -t "$src" -o device) ]] ;;
        /dev/*)     [[ -e $src ]] ;;
        *)          true ;;
    esac && fstab_add+=("$line") || fstab_skip+=("$line")
done < "$B/etc/fstab"

# Unit files written by hand live directly in /etc/systemd/system; packages put
# theirs in /usr/lib and only symlinks here.
units=()
for f in "$B"/etc/systemd/system/*; do
    [[ -f $f && ! -L $f && ! -e /etc/systemd/system/${f##*/} ]] && units+=("${f##*/}")
done

creds=()
while read -r c; do
    [[ -n $c && -f $B$c && ! -e $c ]] && creds+=("$c")
done < <( { printf '%s\n' "${fstab_add[@]}"; for u in "${units[@]}"; do cat "$B/etc/systemd/system/$u"; done; } \
    | grep -oE '(credentials|cred|passwd_file)=/[^,[:space:]]+' | cut -d= -f2 | sort -u)

if (( ${#fstab_add[@]} + ${#units[@]} + ${#creds[@]} == 0 )); then
    echo "Nothing to add."
else
    (( ${#fstab_add[@]} )) && { echo "fstab lines:"; printf '  %s\n' "${fstab_add[@]}"; }
    (( ${#units[@]} ))     && { echo "Units:"; printf '  %s\n' "${units[@]}"; }
    (( ${#creds[@]} ))     && { echo "Credential files:"; printf '  %s\n' "${creds[@]}"; }
    if confirm "Restore them and mount?"; then
        for c in "${creds[@]}"; do
            mkdir -p "$(dirname "$c")"
            cp -a "$B$c" "$c"
        done
        if (( ${#fstab_add[@]} )); then
            cp -a /etc/fstab "$work/fstab.fresh-install"
            { echo; echo "# Restored from backup on $(date -I)"; printf '%s\n' "${fstab_add[@]}"; } >> /etc/fstab
            for line in "${fstab_add[@]}"; do
                read -r _ mnt _ <<<"$line"
                if [[ $mnt == /* ]]; then mkdir -p "$mnt"; fi
            done
        fi
        for u in "${units[@]}"; do
            cp -a "$B/etc/systemd/system/$u" /etc/systemd/system/
            # Enabled units have symlinks in *.wants/ or *.requires/.
            for l in "$B"/etc/systemd/system/*.wants/"$u" "$B"/etc/systemd/system/*.requires/"$u"; do
                [[ -L $l ]] || continue
                mkdir -p "$(dirname "/${l#"$B"/}")"
                cp -P "$l" "/${l#"$B"/}"
            done
        done
        systemctl daemon-reload
        mount -a || warn "some fstab mounts failed, see above"
        for u in "${units[@]}"; do
            case $u in
                *.mount|*.automount|*.timer|*.path)
                    if systemctl is-enabled -q "$u" 2>/dev/null; then
                        systemctl start "$u" || warn "$u failed to start"
                    fi ;;
            esac
        done
        if [[ " ${units[*]} " == *" pve-host-backup.timer "* ]] && ! command -v sqlite3 >/dev/null; then
            apt-get install -y -qq sqlite3 >/dev/null || todo+=("Install sqlite3, pve-host-backup needs it")
        fi
        done_steps+=("Mounts and units")
    else
        skipped_steps+=("Mounts and units")
    fi
fi
if (( ${#fstab_skip[@]} )); then
    warn "these fstab lines refer to disks that aren't here and were left out:"
    printf '  %s\n' "${fstab_skip[@]}"
    todo+=("fstab lines for missing disks, see $B/etc/fstab")
fi

# --- 6. Network --------------------------------------------------------------
step "6/8 Network (/etc/network/interfaces)"
reboot_needed=""
# Physical NICs an interfaces file uses: everything except bridges, bonds and VLANs.
nics_in() {
    awk '
        $1 == "iface" { cur = $2; name[$2] = 1 }
        $1 ~ /^(bridge[-_]ports|bond[-_]slaves|vlan-raw-device)$/ {
            for (i = 2; i <= NF; i++) name[$i] = 1
            if ($1 != "vlan-raw-device") virt[cur] = 1
        }
        END {
            for (n in name)
                if (!(n in virt) && n != "lo" && n != "none" && n !~ /\./ && n !~ /^(vmbr|bond|vlan)/) print n
        }' "$1"
}
nb="$B/etc/network/interfaces"
if [[ ! -f $nb ]] || cmp -s "$nb" /etc/network/interfaces; then
    echo "Nothing to change."
else
    diff -u /etc/network/interfaces "$nb" || true
    missing=()
    for nic in $(nics_in "$nb"); do
        [[ -e /sys/class/net/$nic ]] || missing+=("$nic")
    done
    if (( ${#missing[@]} )); then
        warn "the old configuration uses network cards that aren't here: ${missing[*]} (new hardware?)."
        echo "Not restoring it automatically, adapt $nb by hand."
        todo+=("Network: adapt $nb to this host's NICs")
        skipped_steps+=("Network")
    elif confirm "Use the old network configuration? It takes effect after a reboot."; then
        cp -a /etc/network/interfaces "$work/interfaces.fresh-install"
        cp -a "$nb" /etc/network/interfaces
        if [[ -d $B/etc/network/interfaces.d ]]; then
            cp -a "$B/etc/network/interfaces.d/." /etc/network/interfaces.d/
        fi
        reboot_needed=1
        done_steps+=("Network")
    else
        skipped_steps+=("Network")
    fi
fi

# --- 7. Kernel settings ------------------------------------------------------
step "7/8 Kernel modules, PCI passthrough and sysctl settings"
# merge_params OLD NEW - NEW plus the parameters only OLD had. root= and boot= are
# kept from NEW: they describe the new installation's disks.
merge_params() {
    local out=$2 p old=()
    read -ra old <<<"$1"
    for p in "${old[@]}"; do
        [[ $p == root=* || $p == boot=* || " $out " == *" $p "* ]] || out+=" $p"
    done
    echo "${out# }"
}
grub_default() { bash -c '. "$1" >/dev/null 2>&1; printf %s "${GRUB_CMDLINE_LINUX_DEFAULT:-}"' _ "$1"; }

kfiles=()
for f in "$B"/etc/modules "$B"/etc/modprobe.d/* "$B"/etc/modules-load.d/* "$B"/etc/udev/rules.d/* "$B"/etc/sysctl.d/*; do
    [[ -f $f && ! -L $f ]] || continue
    cmp -s "$f" "/${f#"$B"/}" || kfiles+=("/${f#"$B"/}")
done
new_cmdline="" new_grub=""
if [[ -f $B/etc/kernel/cmdline && -f /etc/kernel/cmdline ]]; then
    cur="$(< /etc/kernel/cmdline)"
    m="$(merge_params "$(< "$B/etc/kernel/cmdline")" "$cur")"
    [[ $m == "$cur" ]] || new_cmdline="$m"
fi
if [[ -f $B/etc/default/grub && -f /etc/default/grub ]]; then
    cur="$(grub_default /etc/default/grub)"
    m="$(merge_params "$(grub_default "$B/etc/default/grub")" "$cur")"
    [[ $m == "$cur" ]] || new_grub="$m"
fi

if (( ${#kfiles[@]} == 0 )) && [[ -z $new_cmdline$new_grub ]]; then
    echo "Nothing to change."
else
    (( ${#kfiles[@]} )) && { echo "Files:"; printf '  %s\n' "${kfiles[@]}"; }
    [[ -n $new_cmdline ]] && echo "/etc/kernel/cmdline: $new_cmdline"
    [[ -n $new_grub ]] && echo "GRUB_CMDLINE_LINUX_DEFAULT: $new_grub"
    if confirm "Apply these? They take effect after a reboot."; then
        tar -C / -cf "$work/kernel-fresh-install.tar" etc/modules etc/modprobe.d etc/modules-load.d \
            etc/udev/rules.d etc/sysctl.d etc/kernel etc/default/grub 2>/dev/null || true
        for f in "${kfiles[@]}"; do
            mkdir -p "$(dirname "$f")"
            cp -a "$B$f" "$f"
        done
        [[ -n $new_cmdline ]] && echo "$new_cmdline" > /etc/kernel/cmdline
        if [[ -n $new_grub ]]; then
            awk -v v="$new_grub" '/^GRUB_CMDLINE_LINUX_DEFAULT=/ { print "GRUB_CMDLINE_LINUX_DEFAULT=\"" v "\""; next } { print }' \
                /etc/default/grub > /etc/default/grub.new && mv /etc/default/grub.new /etc/default/grub
        fi
        update-initramfs -u -k all
        # Hosts booted through proxmox-boot-tool (ZFS, UEFI) don't use grub's config.
        if proxmox-boot-tool status >/dev/null 2>&1; then proxmox-boot-tool refresh; else update-grub; fi
        reboot_needed=1
        done_steps+=("Kernel settings")
    else
        skipped_steps+=("Kernel settings")
    fi
fi

# --- 8. Guests ---------------------------------------------------------------
step "8/8 Virtual machines and containers"
shopt -s nullglob
confs=(/etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf)
shopt -u nullglob
# Newest backup of each guest across all backup storages: "vmid volid ctime".
declare -A bk_volid=() bk_time=()
backups="$(
    for s in $(pvesm status --content backup 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}'); do
        pvesh get "/nodes/$node/storage/$s/content" --content backup --output-format json 2>/dev/null || true
    done | perl -MJSON::PP -e '
        my %n;
        for my $list (JSON::PP->new->incr_parse(do { local $/; <STDIN> } // "")) {
            for my $b (@$list) {
                my $id = $b->{vmid} // next;
                $n{$id} = [$b->{volid}, $b->{ctime}] if !$n{$id} || $b->{ctime} > $n{$id}[1];
            }
        }
        print "$_ @{$n{$_}}\n" for sort { $a <=> $b } keys %n;'
)" || die "can't list the guest backups"
while read -r id volid t; do
    [[ -n $id ]] && bk_volid[$id]=$volid bk_time[$id]=$t
done <<<"$backups"

restore_ids=()
if (( ${#confs[@]} == 0 )); then
    echo "No guest configurations (step 1 restores them)."
else
    for f in "${confs[@]}"; do
        id="$(basename "$f" .conf)"
        kind=vm; [[ $f == */lxc/* ]] && kind=ct
        name="$(awk -F': ' '/^(name|hostname):/ {print $2; exit}' "$f")"
        if [[ -n ${bk_volid[$id]:-} ]]; then
            printf '  %-6s %s  %-24s backup from %s\n' "$id" "$kind" "$name" "$(date -d "@${bk_time[$id]}" '+%F %R')"
            restore_ids+=("$id")
        else
            printf '  %-6s %s  %-24s no backup found, left as is\n' "$id" "$kind" "$name"
            todo+=("Guest $id ($name) has no backup")
        fi
    done
    inactive="$(pvesm status 2>/dev/null | awk 'NR > 1 && $3 != "active" {print $1}' | paste -sd' ')"
    if [[ -n $inactive && -z $RESTORE_STORAGE ]]; then
        warn "storages not available: $inactive. Guests with disks there will fail to restore;"
        echo "         re-run with RESTORE_STORAGE=<storage> to put the disks elsewhere."
    fi
fi

# reapply_lxc_extras SAVED_CONF ID - re-adds bind mounts, device passthrough and raw
# lxc.* lines the restored config lacks.
reapply_lxc_extras() {
    local conf=/etc/pve/lxc/$2.conf line key missing=()
    while IFS= read -r line; do
        [[ $line == \[* ]] && break             # snapshots start here
        [[ $line =~ ^(mp[0-9]+|dev[0-9]+|lxc\.[^:]+): ]] || continue
        key=${BASH_REMATCH[1]}
        grep -q "^${key//./\\.}:" "$conf" || missing+=("$line")
    done < "$1"
    (( ${#missing[@]} )) || return 0
    printf '%s\n' "${missing[@]}" >> "$conf"
    log "Re-added to $2: ${missing[*]}"
}

if (( ${#restore_ids[@]} )) && confirm "Restore these ${#restore_ids[@]} guests from their backups? This can take a while."; then
    mkdir -p "$work/guest-configs"
    opts=()
    [[ -n $RESTORE_STORAGE ]] && opts=(--storage "$RESTORE_STORAGE")
    failed=()
    for id in "${restore_ids[@]}"; do
        conf=/etc/pve/qemu-server/$id.conf
        [[ -f $conf ]] || conf=/etc/pve/lxc/$id.conf
        saved="$work/guest-configs/$id.conf"
        cp "$conf" "$saved"
        # The config points at disks that died; restoring onto a free ID is cleanest.
        rm "$conf"
        log "Restoring $id from ${bk_volid[$id]}"
        if [[ $conf == */lxc/* ]]; then
            if pct restore "$id" "${bk_volid[$id]}" "${opts[@]}"; then
                reapply_lxc_extras "$saved" "$id"
                continue
            fi
        elif qmrestore "${bk_volid[$id]}" "$id" "${opts[@]}"; then
            continue
        fi
        [[ -e $conf ]] || cp "$saved" "$conf"
        failed+=("$id")
    done
    if (( ${#failed[@]} )); then
        todo+=("Guests that failed to restore: ${failed[*]} (configs kept, see the log)")
    fi
    done_steps+=("Guests")
elif (( ${#restore_ids[@]} )); then
    skipped_steps+=("Guests")
fi

# --- Summary -----------------------------------------------------------------
step "Summary"
(( ${#done_steps[@]} ))    && echo "Restored: $(IFS=,; echo "${done_steps[*]}" | sed 's/,/, /g')"
(( ${#skipped_steps[@]} )) && echo "Skipped:  $(IFS=,; echo "${skipped_steps[*]}" | sed 's/,/, /g')"
if (( ${#todo[@]} )); then
    echo "Left for you:"
    printf '  - %s\n' "${todo[@]}"
fi
cat <<EOT

The backup stays in $work. Anything else you changed in /etc shows up with:
  diff -r $B/etc /etc | less
EOT
if [[ -n $reboot_needed ]]; then
    echo "${bold}Reboot now${reset} to apply the network and kernel changes: reboot"
else
    echo "Reboot to check that everything comes up on its own (guests set to start at boot will start)."
fi
