#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 machine for the CADSketch MCP server.
# Run as root ON the server (deploy.sh pipes it over ssh). Safe to re-run.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 512 MB machines need swap for `npm ci`.
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Drop the upstream Caddy repo if an earlier run added it (see below).
rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
apt-get update -qq
apt-get install -y -qq curl ca-certificates rsync >/dev/null

# Node 22 (NodeSource) and Caddy (official repo).
if ! command -v node >/dev/null || ! node -v | grep -q '^v22'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
# Caddy from Ubuntu's own repository. (The upstream cloudsmith repo's signing
# key had expired when this was written, and apt refuses unsigned repos.)
if ! command -v caddy >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi
command -v node >/dev/null || { echo "node failed to install" >&2; exit 1; }
command -v caddy >/dev/null || { echo "caddy failed to install" >&2; exit 1; }

id cadsketch >/dev/null 2>&1 || useradd --system --home /opt/cadsketch-mcp --shell /usr/sbin/nologin cadsketch
mkdir -p /opt/cadsketch-mcp && chown cadsketch:cadsketch /opt/cadsketch-mcp

# Firewall: ssh + web only. The Node server listens on localhost.
ufw allow OpenSSH >/dev/null && ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

echo "setup ok: node $(node -v), $(caddy version | cut -d' ' -f1), ufw $(ufw status | head -1)"
