#!/usr/bin/env bash
# Runs inside the container: installs Caddy, the Cloudflare IP sync (firewall and
# trusted proxies), the Cloudflare certificates and the proxy-site tool.
# Expects origin.pem, origin.key and the scripts pushed to /root by install.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# pct exec passes on the host's locale (e.g. en_US.UTF-8), which the template
# lacks; C.UTF-8 is always available and keeps perl/apt from warning.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Skip rebuilding the man page index after every install; it's slow on a small
# container and nobody reads man pages here.
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
rm -f /var/lib/man-db/auto-update

apt-get update
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg nftables openssl

curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list

apt-get update
apt-get install -y caddy

# Firewall first, so 80/443 are never open to the world while Caddy runs.
install -m 0755 /root/cloudflare-ips.sh /usr/local/sbin/cloudflare-ips
cat > /etc/systemd/system/cloudflare-ips.service <<'EOF'
[Unit]
Description=Apply Cloudflare IP ranges to the firewall and Caddy
Wants=network-online.target
After=network-online.target
Before=caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cloudflare-ips
EOF
cat > /etc/systemd/system/cloudflare-ips.timer <<'EOF'
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
Requires=cloudflare-ips.service
After=cloudflare-ips.service
EOF
systemctl daemon-reload
systemctl start cloudflare-ips.service
systemctl enable --now cloudflare-ips.timer
nft list table inet cf_origin >/dev/null

# Origin CA certificate: what Caddy shows Cloudflare. Only Cloudflare trusts it,
# which is fine because nothing else is allowed to connect.
install -m 0644 -o root -g root /root/origin.pem /etc/caddy/origin.pem
install -m 0640 -o root -g caddy /root/origin.key /etc/caddy/origin.key

# Cloudflare presents a client cert signed by this CA on every request to the
# origin (Authenticated Origin Pulls); Caddy rejects anyone else.
curl -fsSL https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem \
    -o /etc/caddy/cloudflare-origin-pull-ca.pem
chmod 0644 /etc/caddy/cloudflare-origin-pull-ca.pem

install -m 0755 /root/proxy-site /usr/local/sbin/proxy-site
# `pct exec` runs with PATH=/sbin:/bin:/usr/sbin:/usr/bin, which skips /usr/local.
ln -sf /usr/local/sbin/proxy-site /usr/sbin/proxy-site
mkdir -p /etc/caddy/sites

# Global settings only; each site is a file in /etc/caddy/sites/ (see proxy-site).
cat > /etc/caddy/Caddyfile <<'EOF'
# Global settings. Sites live in /etc/caddy/sites/, managed with `proxy-site`.
{
	# Certificates come from Cloudflare's Origin CA (cloudflare_only below), so
	# Caddy never requests any. HTTP->HTTPS redirects stay on.
	auto_https disable_certs

	servers {
		# Only Cloudflare can reach Caddy, so take the real visitor IP from its
		# header. The ranges are refreshed daily by cloudflare-ips.
		import /etc/caddy/cloudflare-ips.caddy
		client_ip_headers CF-Connecting-IP
	}
}

# Imported by every site: serves the Origin CA certificate and rejects TLS
# connections that don't present Cloudflare's origin-pull client certificate
# (Authenticated Origin Pulls).
(cloudflare_only) {
	tls /etc/caddy/origin.pem /etc/caddy/origin.key {
		client_auth {
			mode require_and_verify
			trust_pool file /etc/caddy/cloudflare-origin-pull-ca.pem
		}
	}
}

import /etc/caddy/sites/*.caddy
EOF

systemctl restart caddy
systemctl enable caddy
rm -f /root/setup.sh /root/cloudflare-ips.sh /root/proxy-site /root/origin.pem /root/origin.key
