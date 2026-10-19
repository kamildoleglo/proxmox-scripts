#!/usr/bin/env bash
# Runs inside the container: installs Docker, writes LaraPaper's compose project to
# /opt/larapaper and starts it. Expects the scripts pushed to /root by install.sh and
# LARAPAPER_VERSION, PORT and APP_URL in the environment.
set -euo pipefail
: "${LARAPAPER_VERSION:?}" "${PORT:?}" "${APP_URL:?}"
export DEBIAN_FRONTEND=noninteractive
# pct exec passes on the host's locale (e.g. en_US.UTF-8), which the template
# lacks; C.UTF-8 is always available and keeps perl/apt from warning.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Skip rebuilding the man page index after every install; it's slow on a small
# container and nobody reads man pages here.
echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
rm -f /var/lib/man-db/auto-update

APP_DIR=/opt/larapaper

apt-get update
apt-get install -y ca-certificates curl

# Docker from Docker's own repository; Debian's docker.io lags behind and has no
# compose plugin.
. /etc/os-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

# Cap container logs; Docker keeps them forever by default.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

driver="$(docker info --format '{{.Driver}}')"
if [[ $driver == vfs ]]; then
    echo "warning: Docker fell back to the vfs storage driver, which copies every image" \
        "layer in full. It works, but uses much more disk." >&2
fi

mkdir -p "$APP_DIR"
# Read by compose itself, for the image tag and port.
cat > "$APP_DIR/.env" <<EOF
LARAPAPER_VERSION=$LARAPAPER_VERSION
PORT=$PORT
EOF
# Passed to the app. These override the image's built-in .env, which ships with a
# public example APP_KEY, so a key of our own is required.
umask 077
cat > "$APP_DIR/larapaper.env" <<EOF
APP_KEY=base64:$(head -c 32 /dev/urandom | base64)
# Base of the image URLs sent to the device, so it must be reachable from it.
APP_URL=$APP_URL
# Recommended by LaraPaper; each user sets their own timezone in the web UI.
APP_TIMEZONE=UTC
REGISTRATION_ENABLED=1
PHP_OPCACHE_ENABLE=1
DB_DATABASE=database/storage/database.sqlite
TRMNL_PROXY_REFRESH_MINUTES=15
EOF
umask 022

cat > "$APP_DIR/compose.yml" <<'EOF'
# LaraPaper (https://github.com/usetrmnl/larapaper). Manage with `larapaper`.
# Settings: .env (version, port) and larapaper.env (the app's environment).
services:
  app:
    image: ghcr.io/usetrmnl/larapaper:${LARAPAPER_VERSION}
    ports:
      - "${PORT}:8080"
    env_file: larapaper.env
    volumes:
      - database:/var/www/html/database/storage
      - images:/var/www/html/storage/app/public/images/generated
    restart: unless-stopped
volumes:
  database:
  images:
EOF

install -m 0755 /root/larapaper /usr/local/sbin/larapaper
# `pct exec` runs with PATH=/sbin:/bin:/usr/sbin:/usr/bin, which skips /usr/local.
ln -sf /usr/local/sbin/larapaper /usr/sbin/larapaper

cd "$APP_DIR"
docker compose pull --quiet
docker compose up -d

# The first start runs the database migrations, so give it a while.
echo "Waiting for LaraPaper to answer on port $PORT"
for _ in {1..90}; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
    [[ $code =~ ^[23] ]] && break
    sleep 2
done
if [[ ! $code =~ ^[23] ]]; then
    docker compose logs --tail 30 >&2
    echo "error: LaraPaper didn't come up (last HTTP status: ${code:-none})" >&2
    exit 1
fi

rm -f /root/setup.sh /root/larapaper
