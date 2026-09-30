#!/usr/bin/env bash
set -Eeuo pipefail

# Execute a RouterOS command over SSH. Intended for Fail2ban actions.

LOCK="${LOCK:-/run/lock/mikrotik-fail2ban.lock}"
LOG="${LOG:-/var/log/mikrotik-fail2ban.log}"

ROUTER_HOST="${ROUTER_HOST:-router.example.com}"
ROUTER_USER="${ROUTER_USER:-automation}"
ROUTER_PORT="${ROUTER_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"

exec >>"$LOG" 2>&1

echo
echo "===== $(date -Is) Fail2ban MikroTik command for ${ROUTER_HOST} ====="

if [ "$#" -lt 1 ]; then
  echo "ERROR: missing RouterOS command argument" >&2
  exit 1
fi

REMOTE_CMD="$*"

exec 200>"$LOCK"
flock -w 20 200 || {
  echo "ERROR: could not acquire lock within 20 seconds" >&2
  exit 1
}

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -p "$ROUTER_PORT"
)

if [ -n "$SSH_IDENTITY" ]; then
  SSH_OPTS+=(-i "$SSH_IDENTITY")
fi

echo "Executing remote command:"
echo "$REMOTE_CMD"

ssh "${SSH_OPTS[@]}" "${ROUTER_USER}@${ROUTER_HOST}" "$REMOTE_CMD"

echo "Command completed successfully"
