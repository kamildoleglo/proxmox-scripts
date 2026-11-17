# Marriage course watcher

A small LXC that checks the course list at
[narzeczeni.sosnowiec.pl/kursy-przedmalzenskie](https://narzeczeni.sosnowiec.pl/kursy-przedmalzenskie/)
every 6 hours and sends a mail when:

- **a new course appears** in the table, or
- **a full course gets free seats** (*Dostępne miejsca* goes from 0 to more than 0).

Courses dropping off the list and seat counts going down don't trigger anything.

## Install

In the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/course-watch/install.sh)"
```

It creates an unprivileged Debian 13 container (`course-watch`, 1 core, 256 MiB RAM,
2 GiB disk, DHCP, starts on boot) with Python and a systemd timer. Nothing listens on the
network; the container only fetches the page and sends mail.

**Mail** goes out through an SMTP server. If Proxmox already has an SMTP notification
target (*Datacenter → Notifications*), the installer offers to use the same server,
login and recipients. Otherwise it asks for them; for Gmail that's `smtp.gmail.com`,
`starttls`, port 587 and an [app password](https://myaccount.google.com/apppasswords).
The settings, password included, are kept in `/etc/default/course-watch` inside the
container, readable only by root.

The first check runs during install and mails the current table, so you can see that mail
arrives. If a check fails (the site is down after three tries, or the table is gone
because the page was redesigned), you get one mail about it, and the next one only after
a check has succeeded in between.

### Settings

Run the installer again to update the script: it finds the container by its hostname
and keeps the mail settings. `RECONFIGURE=1` asks for the mail settings again and sends a
test mail.

| Variable | Default | |
|---|---|---|
| `CTID` | *(asked)* | container ID |
| `SMTP_HOST` | *(asked, or Proxmox's SMTP target)* | mail server |
| `SMTP_SECURITY` | `starttls` | `tls`, `starttls` or `none` |
| `SMTP_PORT` | 465 / 587 / 25 | by `SMTP_SECURITY` |
| `SMTP_USER`, `SMTP_PASSWORD` | | login |
| `MAIL_FROM` | `SMTP_USER` | sender address |
| `MAIL_TO` | *(asked)* | recipients, comma-separated |
| `SCHEDULE` | `*-*-* 00/6:00` | systemd [OnCalendar](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html#Calendar%20Events) time (00:00, 06:00, 12:00, 18:00 in the host's time zone, plus up to 20 min) |
| `STORAGE` | `local-lvm` | storage for the container's disk |
| `BRIDGE`, `IP`, `GW` | `vmbr0`, `dhcp` | network |
| `URL` | the course list | page to watch |
| `REPO_REF` | `main` | branch, tag or commit to install from |

### Use

Replace `<CTID>` with the container ID:

```bash
pct exec <CTID> -- course-watch --list                       # print the table as it is now
pct exec <CTID> -- course-watch --test                       # send a test mail
pct exec <CTID> -- systemctl start course-watch              # check now
pct exec <CTID> -- journalctl -u course-watch                # logs
pct exec <CTID> -- systemctl list-timers course-watch.timer  # next run
pct stop <CTID> && pct destroy <CTID>                        # remove it
```

## Running elsewhere

`course-watch` is a single Python 3 file with no dependencies, so it runs on any Linux
box or Mac too. Put the settings in `/etc/default/course-watch` (or point `CONFIG=` at
another file) as `KEY=value` lines (`MAIL_TO`, `SMTP_*`, `MAIL_FROM`), and run it from
cron or a timer every few hours. Without `SMTP_HOST` it sends with the local `sendmail`.

## How it decides

Each course is identified by its link in the table. A link not seen before counts as a new
course. The table is saved after every check, but only after the mail was sent, so a
change isn't lost when the mail server is down; it's reported on the next successful run.
