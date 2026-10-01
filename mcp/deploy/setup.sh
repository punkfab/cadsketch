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

apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg rsync debian-keyring debian-archive-keyring apt-transport-https >/dev/null

# Node 22 (NodeSource) and Caddy (official repo).
if ! command -v node >/dev/null || ! node -v | grep -q '^v22'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
if ! command -v caddy >/dev/null; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq && apt-get install -y -qq caddy >/dev/null
fi

id cadsketch >/dev/null 2>&1 || useradd --system --home /opt/cadsketch-mcp --shell /usr/sbin/nologin cadsketch
mkdir -p /opt/cadsketch-mcp && chown cadsketch:cadsketch /opt/cadsketch-mcp

# Firewall: ssh + web only. The Node server listens on localhost.
ufw allow OpenSSH >/dev/null && ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

echo "setup ok: node $(node -v), $(caddy version | cut -d' ' -f1), ufw $(ufw status | head -1)"
