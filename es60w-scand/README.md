# ES-60W scan button → Paperless

Makes the scan button on an **Epson ES-60W** (WorkForce, Wi-Fi) work without Windows:
press it and everything in the feeder lands as one colour PDF in a folder, typically
[Paperless-ngx](https://docs.paperless-ngx.com/)'s consume directory.

Epson only offers this through its Windows/macOS software (Epson ScanSmart, Event Manager),
and there's no Linux driver that listens for the button. `es60w-scand` is a small daemon,
plain Python with no dependencies, that speaks the scanner's network protocol itself. It
needs no pairing and no Epson software. It runs in the container that has the folder,
usually the Paperless one.

```
ES-60W ──Wi-Fi──► es60w-scand (in the Paperless LXC) ──PDF──► consume dir ──► Paperless
       ◄─ holds the scanner session, gets "button pressed", pulls the pages
```

## Install

Switch the scanner on and connect it to your Wi-Fi first (the Epson Smart Panel app or
the WPS button do that without a computer). Then, in the Proxmox host's shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/kamildoleglo/proxmox-scripts/main/es60w-scand/install.sh)"
```

It asks for:

- **the container**, suggesting a running one named like `paperless`;
- **the output folder**, suggesting Paperless's `PAPERLESS_CONSUMPTION_DIR` when it finds a
  [community-scripts](https://community-scripts.org/scripts/paperless-ngx) install;
- **the scanner's IP** (from your router or the Smart Panel app), which it uses only to
  look up the scanner's MAC address.

It then installs the daemon as a systemd service in the container, starts it and checks
that it reaches the scanner. Run it again to update the daemon; your settings are kept.

To run without prompts, set env vars:

| Variable | Default | |
|---|---|---|
| `CTID` | *(asked)* | container to install into |
| `OUTPUT_DIR` | *(asked)* | folder in the container that gets the PDFs |
| `SCANNER_IP` | *(asked)* | e.g. `192.168.1.40`; used to find the MAC |
| `SCANNER_MAC` | *(looked up)* | e.g. `aa:bb:cc:dd:ee:ff`; set it to skip the lookup |
| `SCAN_*` | see [Settings](#settings) | |
| `REPO_REF` | `main` | branch, tag or commit to install from |

## Using it

Load paper **face down, top edge first** and press the scan button. Pages come out upright,
in order, as `es60w_<date>_<time>.pdf`. A page takes about 5 seconds at 300 dpi.

The scanner runs on battery and turns itself off when idle. That's fine: when it switches
off the daemon lets go, and when it comes back the daemon reconnects within a few seconds
(see [How it works](#how-it-works)). Switch it on, wait about 10 seconds, scan.

## Settings

In `/etc/es60w-scand.env` in the container. After editing, run
`systemctl restart es60w-scand`.

| Setting | Default | |
|---|---|---|
| `SCANNER_HOST` | from the installer | first address tried; updated automatically from the scanner's announcements |
| `SCANNER_MAC` | from the installer | how the daemon recognises the scanner on the network |
| `OUTPUT_DIR` | from the installer | where PDFs go |
| `FALLBACK_DIR` | `/var/lib/es60w-scand/unsent` | used when `OUTPUT_DIR` can't be written (e.g. a NAS share is down), so no scan is lost |
| `SCAN_DPI` | `300` | `200`, `300`, `400` or `600` |
| `SCAN_COLOR` | `C024` | `C024` colour, `M008` grey, `M001` black & white |
| `SCAN_JPEG_Q` | `85` | JPEG quality of the pages, 1–100 |
| `SCAN_MAX_IN` | `14` | longest page in inches; raise it for long receipts (the scanner takes up to 72) |
| `SCAN_TONE` | `1` | `1` applies the levels curve below, `0` sends the raw image |
| `SCAN_BLACK` / `SCAN_WHITE` | `35` / `225` | input levels mapped to black and white. The defaults turn slightly grey paper white and text darker. Lower `SCAN_WHITE` or raise `SCAN_BLACK` for more contrast |
| `SCAN_GAMMA` | `1.15` | midtones; above 1 makes text darker |
| `SCAN_SHARPEN` | `1.2,80,3` | unsharp mask `radius,percent,threshold`; `0` turns it off. Needs `python3-pil`, which the installer adds |

The levels curve is applied by the scanner itself (the same correction tables Epson's
software sends), so it costs nothing. Sharpening re-encodes each page once.

## Managing it

From the Proxmox host (or inside the container without the `pct exec` part):

```bash
pct exec 120 -- journalctl -u es60w-scand -f      # follow the log
pct exec 120 -- systemctl restart es60w-scand     # after changing settings
pct exec 120 -- systemctl stop es60w-scand        # free the scanner for Epson's apps
```

| File | |
|---|---|
| `/opt/es60w-scand/es60w-scand` | the daemon |
| `/etc/es60w-scand.env` | settings, readable by root only |
| `/etc/systemd/system/es60w-scand.service` | the service; restarts on failure and only writes to `OUTPUT_DIR` and `FALLBACK_DIR` |

## How it works

The ES-60W talks to computers over **TCP port 1865** using Epson's "IS" framing with
ESC/I-2 commands, the same protocol SANE's `epsonds` backend and Epson Scan use.

1. **Session.** The daemon connects, locks a session and sends a keepalive every minute.
2. **Button.** The scanner tells whoever holds the session that the button was pressed.
   The daemon then sets the scan parameters (including the tone curve), starts the
   transfer and collects one JPEG per page until the feeder is empty. The scanner pads
   each JPEG and reports the real page height only at the end; the daemon trims the
   padding and fixes the height before wrapping the pages into a PDF without re-encoding
   them (unless sharpening is on).
3. **Saving.** The PDF is written as `….pdf.part`, which Paperless ignores, and renamed to
   the first free `es60w_<date>_<time>[_n].pdf`. Nothing in the folder is ever overwritten
   or deleted.
4. **Power off and on.** Just before it switches off, the scanner sends a "powering off"
   message; the daemon drops the session. While it's off, the daemon listens for the
   scanner's **mDNS (Bonjour) announcement** (`EPSON ES-60W [<MAC>]._scanner._tcp.local`),
   which comes about 6 seconds after it joins the Wi-Fi from its current IP. The daemon
   connects about 3 seconds later. If an announcement is ever missed, it retries every
   5 minutes anyway.

## Notes

- **One program at a time.** The scanner serves a single session, so while the daemon
  runs, Epson Smart Panel and ScanSmart can't scan from it. Stop the service to use them.
- **Nothing else should connect to port 1865.** The scanner treats every TCP connection
  as a session attempt; port scans or uptime monitors pointed at it can make it stop
  answering until you switch it off and on. The daemon only opens the port for its real
  session, and the installer never touches it.
- **Stopping releases the scanner.** `systemctl stop`/`restart` make the daemon unlock the
  session before exiting. If the scanner seems stuck after a crash or a killed process,
  switch it off and on.
- **Paperless's consumer.** If the consume folder is on a network share, the Paperless
  consumer can exit when the share drops for a moment, and nothing gets imported until it
  is restarted. Making it restart on its own helps:
  ```bash
  pct exec 120 -- bash -c 'mkdir -p /etc/systemd/system/paperless-consumer.service.d &&
    printf "[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestart=always\nRestartSec=30\n" \
      > /etc/systemd/system/paperless-consumer.service.d/restart.conf &&
    systemctl daemon-reload && systemctl restart paperless-consumer'
  ```
- **Other Epson scanners.** Epson's other Wi-Fi document scanners (DS-, ES- and FF-series)
  use the same protocol, so this may work with small changes, but only the ES-60W has
  been tested. The feeder width and simplex scanning are set up for it.
- **Backups:** the daemon keeps no state, and the regular Proxmox backup of the container
  covers its files.

Thanks to [epson-scanbutton](https://github.com/bogdanskistefan/epson-scanbutton), whose
protocol notes for the DS-560 showed how the session, button and image transfer work.
