# Host configuration backup

Proxmox's backup jobs (vzdump) save every VM and container, but not the host itself. When
the boot disk dies you get the guests back, while the storage definitions, NFS/SMB
mounts, network setup, users and backup jobs have to be redone by hand.

This adds a nightly backup of the host's configuration to a storage you already back up
to, so a rebuild is a reinstall plus a few copy commands.

## Install

In the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/host-backup/install.sh)"
```

It lists your storages that hold backups and suggests the one your backup jobs use, then
installs `pve-host-backup`, a systemd timer, and runs the first backup. Choose a storage
that is **not on the Proxmox boot disk** (NFS, SMB/CIFS, Proxmox Backup Server, or
another disk); the installer warns if it is.

Run it again to change the settings or update the script. To run without prompts:

| Variable | Default | |
|---|---|---|
| `STORAGE` | *(asked)* | Proxmox storage ID with *VZDump backup file* content |
| `KEEP` | `14` | how many backups to keep |
| `SCHEDULE` | `*-*-* 04:00` | systemd [OnCalendar](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events) time |
| `REPO_REF` | `main` | branch, tag or commit to install from |

If a backup fails, a mail goes to root, which Proxmox forwards to your notification
targets (*Datacenter → Notifications*), the same as failed guest backups.

```bash
systemctl start pve-host-backup          # back up now
journalctl -u pve-host-backup            # logs
systemctl list-timers pve-host-backup    # next run
```

## What's in it

| Path | Covers |
|---|---|
| `pve-host-backup/config.db` | everything under `/etc/pve`: storages (including NFS/SMB/PBS passwords), backup jobs, users and permissions, firewall, notification targets, guest configs, node certificates |
| `etc/` | the whole `/etc`, including a readable copy of `/etc/pve`: `fstab`, systemd `.mount` units, SMB credential files, network, `subuid`/`subgid`, apt sources, passthrough settings (`modprobe.d`, `kernel/cmdline`, `default/grub`) |
| `root/`, `usr/local/`, `var/spool/cron/` | SSH keys, your own scripts, crontabs |
| `pve-host-backup/info/` | what the host looked like: installed packages, `pveversion -v`, disks (`lsblk`, `blkid`, ZFS, LVM), mounts, IP addresses, PCI devices |

Where it goes:

- **Directory, NFS, SMB/CIFS storages:** `pve-host-<hostname>-<date>.tar.zst` in the
  storage's `dump/` folder, next to the vzdump files (e.g. `/mnt/pve/nas/dump/`). The
  Proxmox UI doesn't list them.
- **Proxmox Backup Server:** a backup group `host/<hostname>`, visible in the PBS UI. If
  the storage uses client-side encryption, the host backup uses the same key.

The backup contains secrets (storage passwords, SSH keys, the PBS encryption key) and is
readable only by root, like the vzdump files next to it. If you use PBS encryption, keep
a copy of the key somewhere off the host, as Proxmox suggests when you create it: you
need it to restore anything after the disk is gone.

## Restore

After replacing the disk:

1. **Reinstall Proxmox** with the **same hostname** and the same local storage type
   (LVM or ZFS) as before. If you're not sure, `pve-host-backup/info/` in the backup
   has `hostname` and `lsblk`.

2. **Add the backup storage** again in *Datacenter → Storage → Add*, the one storage
   you need by hand. Use the same ID as before (it gets replaced in step 4 anyway).

3. **Get the latest backup** into `/root/restore`:

   ```bash
   mkdir /root/restore && cd /root/restore
   # Directory/NFS/SMB storage (here "nas"):
   tar --zstd -xf "$(ls /mnt/pve/nas/dump/pve-host-*.tar.zst | tail -n1)"
   ```

   For Proxmox Backup Server (storage `pbs`, use your hostname and add `--ns <name>` if
   you use a namespace):

   ```bash
   export PBS_REPOSITORY='root@pam@192.168.1.5:main' PBS_PASSWORD="$(cat /etc/pve/priv/storage/pbs.pw)"
   proxmox-backup-client snapshot list host/pve
   snap=host/pve/2026-10-19T04:00:00Z                        # pick one from the list
   for a in meta:pve-host-backup etc:etc root:root usr-local:usr/local; do
       proxmox-backup-client restore "$snap" "${a%%:*}.pxar" "${a#*:}"   # add --keyfile if encrypted
   done
   ```

4. **Put `/etc/pve` back.** This restores storages (with their NFS/SMB/PBS
   credentials), backup jobs, users, firewall rules, notifications and guest configs:

   ```bash
   systemctl stop pve-cluster
   install -m 0600 /root/restore/pve-host-backup/config.db /var/lib/pve-cluster/config.db
   rm -f /var/lib/pve-cluster/config.db-wal /var/lib/pve-cluster/config.db-shm
   systemctl start pve-cluster
   systemctl restart pvedaemon pveproxy pvestatd
   ```

   Reload the web UI (you may need to accept the restored certificate). Storages
   defined in Proxmox, such as NFS and SMB shares under `/mnt/pve/`, mount on their own.

5. **Mounts made outside Proxmox**, in `/etc/fstab` or as systemd units (typical for
   shares bind-mounted into containers). Compare and copy what you need, don't replace
   `/etc` wholesale, since a fresh install has its own disk UUIDs and machine identity:

   ```bash
   cd /root/restore
   diff etc/fstab /etc/fstab
   grep -hoE '(credentials|cred)=[^,[:space:]]+' etc/fstab   # credential files to copy back
   ls etc/systemd/system/*.mount etc/systemd/system/*.automount 2>/dev/null
   ```

   Then copy over the lines, credential files and units, create the mount points
   (`mkdir -p`), and run `systemctl daemon-reload && mount -a` (or
   `systemctl enable --now <unit>.mount`).

6. **Other host settings**, where you changed them:

   ```bash
   cp etc/subuid etc/subgid /etc/                  # ID mappings for unprivileged containers
   diff etc/network/interfaces /etc/network/interfaces   # NIC names can differ on new hardware
   cp -a root/.ssh /root/                          # SSH keys
   ```

   Also look at `etc/apt/sources.list.d/`, `etc/modprobe.d/` and `etc/kernel/cmdline`
   or `etc/default/grub` (PCI passthrough), crontabs in `var/spool/cron/`, and
   `pve-host-backup/info/packages-manual` for packages you installed yourself. Reboot
   when done.

7. **Restore the guests.** Their configs are back from step 4 but their disks aren't.
   In the UI, open each guest → *Backup* → pick the latest → *Restore*, or from the
   shell:

   ```bash
   pct restore 101 /mnt/pve/nas/dump/vzdump-lxc-101-....tar.zst --force
   qmrestore /mnt/pve/nas/dump/vzdump-qemu-100-....vma.zst 100 --force
   ```

## Notes

- To restore a single file, extract just that path, e.g.
  `tar --zstd -xOf pve-host-....tar.zst etc/pve/storage.cfg`.
- `/etc/pve` is restored from `config.db` rather than the copy under `etc/pve/`,
  because the database is the real store behind it. The copy is for reading and
  cherry-picking single files, which you can copy into a running `/etc/pve`.
- For a cluster, restoring `config.db` on one node isn't the right fix: the other nodes
  still have the configuration. Rejoin the reinstalled node to the cluster instead and
  use this backup only for the host-local settings (steps 5 and 6).
