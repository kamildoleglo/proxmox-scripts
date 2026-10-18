# Host configuration backup

Proxmox's backup jobs (vzdump) save every VM and container, but not the host itself. When
the boot disk dies you get the guests back, while the storage definitions, NFS/SMB
mounts, network setup, users and backup jobs have to be redone by hand.

This adds a nightly backup of the host's configuration to a storage you already back up
to, and a restore script that rebuilds the host from it after a reinstall.

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
| `root/`, `usr/local/`, `var/spool/cron/`, `usr/share/keyrings/` | SSH keys, your own scripts, crontabs, keys of third-party apt repositories |
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
   (LVM or ZFS) as before.
2. **Add the backup storage** again in *Datacenter → Storage → Add*, the one storage
   you need to add by hand. For PBS with encryption, upload your saved key there too.
3. **Run the restore script** in the host's shell:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/host-backup/restore.sh)"
   ```

It takes the newest backup of this host, then goes through the steps below. Each step
shows what it would change and asks first (`YES=1` answers yes to everything). The
replaced files are saved next to the extracted backup in `/root/pve-host-restore.*/`,
along with a log.

| Step | What it does |
|---|---|
| 1. Proxmox configuration | puts `/etc/pve` back: storages (NFS/SMB/PBS shares mount on their own), backup jobs, users, firewall, notifications, guest configs |
| 2. Files | `/root`, `/usr/local` and crontabs, keeping files that already exist; root's and the host's SSH keys are replaced so that machines that trust them keep working |
| 3. ID mappings | adds the missing `/etc/subuid` and `/etc/subgid` lines for unprivileged containers |
| 4. Apt and packages | restores the repositories (only if the Proxmox major version is the same) and installs the packages you had installed yourself |
| 5. Mounts | adds the `/etc/fstab` lines for network shares and disks that are still there, the credential files they use, and your own systemd units (`.mount`, timers, ...), then mounts |
| 6. Network | uses the old `/etc/network/interfaces`, but only if every network card it names exists |
| 7. Kernel settings | `modprobe.d`, `modules`, `udev` and `sysctl` files, and adds the old kernel parameters (e.g. `intel_iommu=on`) to the new ones, for PCI passthrough |
| 8. Guests | restores every VM and container from its newest backup on any storage, then re-adds container bind mounts and device passthrough if the restore dropped them |

At the end it lists what it couldn't do, such as fstab lines for disks that are gone or
guests without a backup. Reboot afterwards; guests set to start at boot come up then.

Options, as env vars before `bash -c`:

| Variable | |
|---|---|
| `SOURCE` | the storage holding the backup, or the path of a `.tar.zst` (asked otherwise) |
| `RESTORE_STORAGE` | where to put the guest disks, if their old storage doesn't exist anymore (e.g. you switched from LVM to ZFS) |
| `YES=1` | answer yes to every question |

<details>
<summary>Restoring by hand</summary>

Extract the newest `pve-host-<hostname>-*.tar.zst` from the storage's `dump/` folder
(for PBS: `proxmox-backup-client restore host/<hostname>/<time> etc.pxar etc`, and the
same for `meta.pxar` into `pve-host-backup`), then in that folder:

```bash
# /etc/pve
systemctl stop pve-cluster
install -m 0600 pve-host-backup/config.db /var/lib/pve-cluster/config.db
rm -f /var/lib/pve-cluster/config.db-wal /var/lib/pve-cluster/config.db-shm
systemctl start pve-cluster
systemctl restart pvedaemon pveproxy pvestatd pvescheduler

# Mounts: copy the lines you need, plus their credential files and mount points
diff etc/fstab /etc/fstab
ls etc/systemd/system/
cat etc/subuid etc/subgid
```

Don't copy `/etc` over wholesale: a fresh install has its own disk UUIDs and machine
identity. For each guest, remove its config (its disks are gone) and restore it:

```bash
rm /etc/pve/lxc/101.conf && pct restore 101 nas:backup/vzdump-lxc-101-....tar.zst
rm /etc/pve/qemu-server/100.conf && qmrestore nas:backup/vzdump-qemu-100-....vma.zst 100
```

</details>

## Notes

- To restore a single file, extract just that path, e.g.
  `tar --zstd -xOf pve-host-....tar.zst etc/pve/storage.cfg`.
- `/etc/pve` is restored from `config.db` rather than the copy under `etc/pve/`,
  because the database is the real store behind it. The copy is for reading and
  cherry-picking single files, which you can copy into a running `/etc/pve`.
- For a cluster, restoring `config.db` on one node isn't the right fix: the other nodes
  still have the configuration. The restore script skips step 1 for a cluster node;
  rejoin it to the cluster and let the script do the host-local steps.
