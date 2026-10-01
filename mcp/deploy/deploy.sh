#!/usr/bin/env bash
# Build locally and deploy the MCP server to the droplet. From mcp/:
#   deploy/deploy.sh            # deploy
#   deploy/deploy.sh --setup    # first time on a fresh machine (then deploys)
# The repo is private, so nothing is cloned on the server: only dist/ and the
# package manifests are copied, and runtime deps are installed there.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${CADSKETCH_MCP_HOST:-root@64.23.228.132}"
SSH="ssh -o BatchMode=yes $HOST"

if [[ "${1:-}" == "--setup" ]]; then
  $SSH 'bash -s' < deploy/setup.sh
fi

npm run build
rsync -az --delete dist package.json package-lock.json "$HOST:/opt/cadsketch-mcp/"
rsync -az deploy/cadsketch-mcp.service "$HOST:/etc/systemd/system/cadsketch-mcp.service"
rsync -az deploy/Caddyfile "$HOST:/etc/caddy/Caddyfile"
$SSH 'set -e
  chown -R cadsketch:cadsketch /opt/cadsketch-mcp
  cd /opt/cadsketch-mcp && sudo -u cadsketch env HOME=/opt/cadsketch-mcp npm ci --omit=dev --no-audit --no-fund 2>&1 | tail -1
  systemctl daemon-reload
  systemctl enable -q cadsketch-mcp
  systemctl restart cadsketch-mcp
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy
  sleep 2
  systemctl is-active cadsketch-mcp
  curl -fsS http://127.0.0.1:3001/ | head -1'
