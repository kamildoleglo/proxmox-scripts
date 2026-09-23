#!/usr/bin/env bash
# Runs inside the container: installs Caddy (with Cloudflare modules), the
# Cloudflare origin-pull CA, the Cloudflare-only firewall and the proxy-site tool.
# Expects ACME_EMAIL in the environment and the files pushed to /root by install.sh.
set -euo pipefail
: "${ACME_EMAIL:?}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg nftables

curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list

apt-get update
apt-get install -y caddy

# Firewall first, so 80/443 are never open to the world while Caddy runs.
install -m 0755 /root/cf-origin-firewall.sh /usr/local/sbin/cf-origin-firewall
cat > /etc/systemd/system/cf-origin-firewall.service <<'EOF'
[Unit]
Description=Restrict ports 80/443 to Cloudflare IP ranges
Wants=network-online.target
After=network-online.target
Before=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cf-origin-firewall
EOF
cat > /etc/systemd/system/cf-origin-firewall.timer <<'EOF'
[Unit]
Description=Refresh Cloudflare IP ranges daily

[Timer]
OnBootSec=0
OnUnitActiveSec=1d
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/cloudflare.conf <<'EOF'
[Unit]
Requires=cf-origin-firewall.service
After=cf-origin-firewall.service

[Service]
EnvironmentFile=/etc/caddy/caddy.env
EOF
systemctl daemon-reload
systemctl start cf-origin-firewall.service
systemctl enable --now cf-origin-firewall.timer
nft list table inet cf_origin >/dev/null

# Cloudflare presents a client cert signed by this CA on every request to the
# origin (Authenticated Origin Pulls); Caddy rejects anyone else.
curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
    -o /etc/caddy/cloudflare-origin-pull-ca.pem
chmod 0644 /etc/caddy/cloudflare-origin-pull-ca.pem

install -m 0600 -o root -g root /root/caddy.env /etc/caddy/caddy.env
install -m 0755 /root/proxy-site /usr/local/sbin/proxy-site
mkdir -p /etc/caddy/sites

# Global settings only; each site is a file in /etc/caddy/sites/ (see proxy-site).
cat > /etc/caddy/Caddyfile <<EOF
# Global settings. Sites live in /etc/caddy/sites/, managed with \`proxy-site\`.
{
	email $ACME_EMAIL

	# Certificates via Cloudflare DNS challenge: works behind Cloudflare's proxy
	# and needs no inbound port 80.
	acme_dns cloudflare {env.CF_API_TOKEN}

	servers {
		# Only Cloudflare can reach Caddy, so take the real visitor IP from its
		# header (Cloudflare's IP ranges are fetched and refreshed automatically).
		trusted_proxies cloudflare
		client_ip_headers CF-Connecting-IP
	}
}

# Imported by every site: rejects TLS connections that don't present Cloudflare's
# origin-pull client certificate (Authenticated Origin Pulls).
(cloudflare_only) {
	tls {
		client_auth {
			mode require_and_verify
			trust_pool file /etc/caddy/cloudflare-origin-pull-ca.pem
		}
	}
}

import /etc/caddy/sites/*.caddy
EOF

# Swaps in a Caddy binary with the DNS (certs) and trusted-proxy modules. apt
# upgrades would drop them again, so hold the package and use `caddy upgrade`.
caddy add-package github.com/caddy-dns/cloudflare github.com/WeidiDeng/caddy-cloudflare-ip
apt-mark hold caddy

systemctl restart caddy
systemctl enable caddy
rm -f /root/setup.sh /root/cf-origin-firewall.sh /root/proxy-site /root/caddy.env
