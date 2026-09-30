#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Renew a Let's Encrypt certificate with Certbot webroot authentication and,
# when it changes, upload it to MikroTik RouterOS over SSH.

ROUTER_HOST="${ROUTER_HOST:-}"
ROUTER_USER="${ROUTER_USER:-automation}"
ROUTER_PORT="${ROUTER_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"

DOMAIN="${DOMAIN:-}"
WEBROOT="${WEBROOT:-}"
CERT_DIR="${CERT_DIR:-}"

NAT_RULE_COMMENT="${NAT_RULE_COMMENT:-letsencrypt-webroot}"
IMPORT_SCRIPT="${IMPORT_SCRIPT:-CertificateImport}"

LOCK="${LOCK:-/run/lock/mikrotik-letsencrypt.lock}"
LOG="${LOG:-/var/log/mikrotik-letsencrypt.log}"

: "${ROUTER_HOST:?Set ROUTER_HOST to the MikroTik hostname or IP address}"
: "${DOMAIN:?Set DOMAIN to the certificate name}"
: "${WEBROOT:?Set WEBROOT to the Certbot webroot directory}"

CERT_DIR="${CERT_DIR:-/etc/letsencrypt/live/${DOMAIN}}"

exec >>"$LOG" 2>&1

echo
echo "===== $(date -Is) starting ${DOMAIN} certificate renewal/import ====="

exec 200>"$LOCK"
flock -n 200 || {
  echo "Another certificate synchronization is already running. Exiting."
  exit 0
}

for cmd in certbot openssl ssh scp flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  }
done

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -p "$ROUTER_PORT"
)

SCP_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
  -P "$ROUTER_PORT"
)

if [ -n "$SSH_IDENTITY" ]; then
  SSH_OPTS+=(-i "$SSH_IDENTITY")
  SCP_OPTS+=(-i "$SSH_IDENTITY")
fi

ROUTER_TARGET="${ROUTER_USER}@${ROUTER_HOST}"

router_ssh() {
  ssh "${SSH_OPTS[@]}" "$ROUTER_TARGET" "$1"
}

nat_enabled=0

set_nat_rule() {
  local action="$1"

  router_ssh ":local r [/ip firewall nat find where comment=\"${NAT_RULE_COMMENT}\"]; :if ([:len \$r] != 1) do={ :error \"expected exactly one NAT rule with comment ${NAT_RULE_COMMENT}\" }; /ip firewall nat ${action} \$r"
}

cleanup() {
  local rc=$?

  if [ "$nat_enabled" -eq 1 ]; then
    echo "Disabling temporary NAT rule '${NAT_RULE_COMMENT}' on ${ROUTER_HOST}"
    set_nat_rule disable || true
  fi

  echo "===== $(date -Is) finished ${DOMAIN} certificate renewal/import with exit code ${rc} ====="
  exit "$rc"
}
trap cleanup EXIT INT TERM

cert_fingerprint() {
  local cert="${CERT_DIR}/fullchain.pem"

  if [ -s "$cert" ]; then
    openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null || true
  fi
}

# Make sure SSH works before changing the firewall.
echo "Testing RouterOS SSH connection"
router_ssh ':put "ssh-ok"' >/dev/null

echo "Enabling temporary NAT rule '${NAT_RULE_COMMENT}' on ${ROUTER_HOST}"
set_nat_rule enable
nat_enabled=1

before="$(cert_fingerprint)"

echo
echo "Checking certificate for ${DOMAIN}"
certbot certonly \
  --webroot \
  --webroot-path "$WEBROOT" \
  --keep-until-expiring \
  -n \
  -d "$DOMAIN"

after="$(cert_fingerprint)"

echo
echo "Disabling temporary NAT rule '${NAT_RULE_COMMENT}' on ${ROUTER_HOST}"
set_nat_rule disable
nat_enabled=0

if [ -z "$after" ]; then
  echo "ERROR: certificate not found after Certbot run: ${CERT_DIR}/fullchain.pem" >&2
  exit 1
fi

if [ "$before" = "$after" ] && [ "${FORCE_IMPORT:-0}" != "1" ]; then
  echo "Certificate unchanged for ${DOMAIN}. Skipping MikroTik upload/import."
  exit 0
fi

if [ "${FORCE_IMPORT:-0}" = "1" ]; then
  echo "FORCE_IMPORT=1 set. Uploading/importing the existing certificate."
else
  echo "Certificate changed for ${DOMAIN}. Uploading/importing to MikroTik."
fi

test -s "${CERT_DIR}/fullchain.pem"
test -s "${CERT_DIR}/privkey.pem"

echo "Removing old temporary certificate files from MikroTik if present"
router_ssh ':do { /file remove [find name="fullchain.pem"] } on-error={ }'
router_ssh ':do { /file remove [find name="privkey.pem"] } on-error={ }'

echo "Uploading certificate files to ${ROUTER_HOST}"
scp "${SCP_OPTS[@]}" "${CERT_DIR}/fullchain.pem" "${ROUTER_TARGET}:/fullchain.pem"
scp "${SCP_OPTS[@]}" "${CERT_DIR}/privkey.pem" "${ROUTER_TARGET}:/privkey.pem"

echo "Running RouterOS certificate import script: ${IMPORT_SCRIPT}"
router_ssh "/system script run ${IMPORT_SCRIPT}"

echo "${DOMAIN} certificate renewal/import completed successfully"