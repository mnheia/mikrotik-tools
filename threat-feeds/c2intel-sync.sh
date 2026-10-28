#!/usr/bin/env bash
# IPv4 threat feed synchronization for MikroTik RouterOS.
# Copyright (c) 2026, mnheia
# Fail-closed synchronization; unrelated address-list entries are never changed.
set -Eeuo pipefail

# Generic, public feed synchronizer. Supply router-specific settings via the
# environment or a local root-readable configuration file OUTSIDE this repository.
# Do not put passwords, private hostnames or credential files in Git.
FWL_HOST="${ROUTER_HOST:-}"
FWL_USER="${ROUTER_USER:-automation}"
FWL_PORT="${ROUTER_PORT:-22}"
PASS_FILE="${SSH_PASSWORD_FILE:-}"
SSH_IDENTITY="${SSH_IDENTITY:-}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/drb-ra/C2IntelFeeds/master/feeds/IPC2s.csv}"
ADDRESS_LIST="${ADDRESS_LIST:-botnet}"
TIMEOUT="${TIMEOUT:-8d}"
BATCH_SIZE="${BATCH_SIZE:-8}"
MIN_ENTRIES="${MIN_ENTRIES:-20}"
MAX_ENTRIES="${MAX_ENTRIES:-2000}"
OWNER_PREFIX="c2intel-"
FEED_NAME="C2IntelFeeds verified C2"
LOG="${LOG_FILE:-/var/log/mikrotik-c2intel-sync.log}"
LOCK="${LOCK_FILE:-/run/lock/mikrotik-c2intel-sync.lock}"
# Share ROUTER_LOCK across updaters targeting the SAME router.
ROUTER_LOCK="${ROUTER_LOCK:-/run/lock/mikrotik-feed-router.lock}"
SSH_EXEC_TIMEOUT="${SSH_EXEC_TIMEOUT:-90}"
SSH_AUTH_RETRY_DELAY="${SSH_AUTH_RETRY_DELAY:-90}"
SSH_NETWORK_RETRY_DELAY="${SSH_NETWORK_RETRY_DELAY:-15}"
BATCH_PAUSE="${BATCH_PAUSE:-2}"
SSH_MIN_INTERVAL="${SSH_MIN_INTERVAL:-12}"

exec >>"$LOG" 2>&1
printf '\n===== %s starting %s synchronization for %s =====\n' "$(date -Is)" "$FEED_NAME" "$FWL_HOST"
trap 'status=$?; printf "ERROR: line %s failed with exit code %s: %s\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

if [[ -z "$FWL_HOST" ]]; then
    echo "ERROR: ROUTER_HOST must be set in your local environment." >&2
    exit 1
fi
if [[ ! "$FWL_HOST" =~ ^[A-Za-z0-9.-]+$ || ! "$FWL_USER" =~ ^[A-Za-z0-9_.-]+$ ||
      ! "$FWL_PORT" =~ ^[0-9]+$ || ! "$ADDRESS_LIST" =~ ^[A-Za-z0-9_-]+$ ||
      ! "$TIMEOUT" =~ ^[0-9]+[smhdw]([0-9]+[smhdw])*$ ]]; then
    echo "ERROR: invalid router, user, port, list or timeout setting." >&2
    exit 1
fi
if [[ -n "$PASS_FILE" && ! -r "$PASS_FILE" ]]; then
    echo "ERROR: SSH_PASSWORD_FILE cannot be read." >&2
    exit 1
fi
if [[ -z "$PASS_FILE" && -n "$SSH_IDENTITY" && ! -r "$SSH_IDENTITY" ]]; then
    echo "ERROR: SSH_IDENTITY cannot be read." >&2
    exit 1
fi
for cmd in wget jq python3 sshpass ssh timeout sort wc tr flock mktemp sleep grep cat date; do
    # jq is only used for Spamhaus.
    if [[ "$cmd" == jq && "$OWNER_PREFIX" != 'spamhaus-drop-' ]]; then continue; fi
    if [[ "$cmd" == sshpass && -z "$PASS_FILE" ]]; then continue; fi
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $cmd" >&2; exit 1; }
done

exec 200>"$LOCK"
if ! flock -n 200; then
    echo "Another instance of this updater is already running; nothing changed."
    exit 0
fi
exec 201>"$ROUTER_LOCK"
if ! flock -w 120 201; then
    echo "ERROR: another threat-feed updater is still using this router (120s timeout)." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT
RAW_FEED="$WORKDIR/downloaded.feed"
IP_LIST="$WORKDIR/validated-ipv4.txt"
ROS_SCRIPT="$WORKDIR/routeros-commands.txt"
SSH_LAST_ATTEMPT_FILE="$WORKDIR/last-ssh-attempt"  # File survives command-substitution subshells.

# Capture errors even under set -e and -o pipefail. This function prints only stdout on success.
# Never use sshpass -p: the password remains exclusively in the protected local file.
# Rate limit all SSH logins, not only write batches. Each call runs inside
# command substitution, so throttle state must live in a file, not a variable.
ssh_throttle() {
    local now previous wait
    now="$(date +%s)"
    if [[ -r "$SSH_LAST_ATTEMPT_FILE" ]]; then
        previous="$(cat "$SSH_LAST_ATTEMPT_FILE")"
        if [[ "$previous" =~ ^[0-9]+$ ]] && (( now >= previous )); then
            wait=$(( SSH_MIN_INTERVAL - (now - previous) ))
            if (( wait > 0 )); then sleep "$wait"; fi
        fi
    fi
    date +%s > "$SSH_LAST_ATTEMPT_FILE"
}

ssh_exec() {
    local remote="$1" output status attempt delay
    local -a ssh_command=(ssh -n -T)
    if [[ -n "$PASS_FILE" ]]; then
        # Password stays in a private local file, never on the command line.
        ssh_command=(sshpass -f "$PASS_FILE" ssh -n -T
            -o PubkeyAuthentication=no
            -o PreferredAuthentications=password,keyboard-interactive
            -o NumberOfPasswordPrompts=1)
    else
        ssh_command+=( -o BatchMode=yes -o PreferredAuthentications=publickey )
        if [[ -n "$SSH_IDENTITY" ]]; then
            ssh_command+=( -o IdentitiesOnly=yes -i "$SSH_IDENTITY" )
        fi
    fi
    for attempt in 1 2; do
        ssh_throttle
        if output="$(
            timeout -k 5s "$SSH_EXEC_TIMEOUT" \
            "${ssh_command[@]}" \
              -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=15 \
              -o ServerAliveInterval=15 \
              -o ServerAliveCountMax=4 \
              -p "$FWL_PORT" \
              "${FWL_USER}@${FWL_HOST}" "$remote" 2>&1
        )"; then
            printf '%s\n' "$output"
            return 0
        else
            status=$?
        fi
        printf 'WARNING: MikroTik SSH attempt %s failed (exit %s; timeout exit is 124).\n' \
          "$attempt" "$status" >&2
        printf '%s\n' "$output" >&2
        # Host-key mismatch and bad password-file errors are not transient.
        if [[ "$output" == *'REMOTE HOST IDENTIFICATION HAS CHANGED'* ]] ||
           [[ "$output" == *'Host key verification failed'* ]] ||
           [[ "$status" -eq 5 ]]; then
            echo 'ERROR: SSH authentication/host verification requires manual attention.' >&2
            return 1
        fi
        if (( attempt == 2 )); then
            echo 'ERROR: MikroTik SSH failed again after one delayed retry.' >&2
            return 1
        fi
        if [[ "$output" == *'Permission denied'* ]]; then
            delay="$SSH_AUTH_RETRY_DELAY"
        elif (( status == 124 || status == 255 )); then
            delay="$SSH_NETWORK_RETRY_DELAY"
        else
            echo 'ERROR: Non-transient SSH failure; not retrying.' >&2
            return 1
        fi
        printf 'WARNING: Cooling down %s seconds before ONE retry.\n' "$delay" >&2
        sleep "$delay"
    done
    return 1
}

remote_count() {
    local value
    if ! value="$(ssh_exec "$1")"; then return 1; fi
    value="$(printf '%s' "$value" | tr -d '\r[:space:]')"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid RouterOS count response: $value" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# Download and fully validate BEFORE writing any router entries.
echo "Downloading $FEED_NAME feed: $SOURCE_URL"
if ! wget -q -T 30 --tries=3 -O "$RAW_FEED" "$SOURCE_URL"; then
    echo "ERROR: download failed; MikroTik unchanged." >&2; exit 1
fi
if [[ ! -s "$RAW_FEED" ]]; then echo "ERROR: empty feed; MikroTik unchanged." >&2; exit 1; fi
echo "Download size: $(wc -c < "$RAW_FEED") bytes"

python3 - "$RAW_FEED" "$IP_LIST" <<'PYBOT'
import csv
import ipaddress
import sys

src, dst = sys.argv[1:3]
unique = set()
row_count = 0
skipped = 0
with open(src, encoding="utf-8-sig", newline="") as fd:
    for line_num, row in enumerate(csv.reader(fd), 1):
        if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
            continue
        row_count += 1
        try:
            ip = ipaddress.ip_address(row[0].strip())
        except ValueError as exc:
            sys.exit(f"Invalid C2 feed IP at line {line_num}: {exc}")
        if ip.version != 4:
            sys.exit(f"IPv6 found in IPv4 C2 feed at line {line_num}")
        if not ip.is_global:
            skipped += 1
            continue
        unique.add(str(ip))
if row_count == 0 or not unique:
    sys.exit("C2 feed has no valid globally routable IPv4 entries")
with open(dst, "w", encoding="ascii") as fd:
    fd.write("\n".join(sorted(unique, key=lambda x: int(ipaddress.IPv4Address(x)))) + "\n")
print(f"Feed rows: {row_count}; globally routable IPv4: {len(unique)}; skipped non-global: {skipped}")
PYBOT

TOTAL_COUNT="$(wc -l < "$IP_LIST" | tr -d ' ')"
if (( TOTAL_COUNT < MIN_ENTRIES || TOTAL_COUNT > MAX_ENTRIES )); then
    echo "ERROR: unexpected $FEED_NAME entry count: $TOTAL_COUNT (allowed $MIN_ENTRIES..$MAX_ENTRIES); router unchanged." >&2
    exit 1
fi
GENERATION="${OWNER_PREFIX}$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "Validated IPv4 entries: $TOTAL_COUNT; generation: $GENERATION"

# Each request reports an individual success marker. A connection success or final
# marker alone is NOT proof that RouterOS actually applied each command.
# Foreign entries in shared lists (including Fail2Ban's 'threat') must never be
# overwritten or deleted. Any exact-address collision aborts stale cleanup.
echo "Building RouterOS requests"
while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    printf ':do { :local ids [/ip firewall address-list find where list="%s" and address="%s"]; :if ([:len $ids] = 0) do={ /ip firewall address-list add list="%s" address="%s" timeout=%s comment="%s" } else={ :foreach id in=$ids do={ :local c [:tostr [/ip firewall address-list get $id comment]]; :if ([:pick $c 0 %s] = "%s") do={ /ip firewall address-list set $id timeout=%s comment="%s" } else={ :put "SYNC_CONFLICT:%s"; :error "foreign entry" } } }; :put "SYNC_OK:%s" } on-error={ :put "SYNC_FAIL:%s" }\n' \
        "$ADDRESS_LIST" "$addr" "$ADDRESS_LIST" "$addr" "$TIMEOUT" "$GENERATION" \
        "${#OWNER_PREFIX}" "$OWNER_PREFIX" "$TIMEOUT" "$GENERATION" "$addr" "$addr" "$addr"
done < "$IP_LIST" > "$ROS_SCRIPT"
if [[ "$(wc -l < "$ROS_SCRIPT" | tr -d ' ')" -ne "$TOTAL_COUNT" ]]; then
    echo "ERROR: generated command count mismatch; router unchanged." >&2; exit 1
fi

echo "Testing MikroTik SSH connection to $FWL_HOST"
if ! SSH_TEST="$(ssh_exec ':put "sync-ssh-test-ok"')"; then
    echo "ERROR: SSH preflight failed; no router changes were attempted." >&2; exit 1
fi
if [[ "$(printf '%s' "$SSH_TEST" | tr -d '\r[:space:]')" != "sync-ssh-test-ok" ]]; then
    echo "ERROR: unexpected SSH test response: $SSH_TEST" >&2; exit 1
fi
echo "SSH preflight OK"

BEFORE="$(remote_count "/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\"")" || exit 1
echo "Existing $ADDRESS_LIST entries (all owners): $BEFORE"

BATCH_NUMBER=0
PROCESSED=0
run_batch() {
    local commands="" line output ok_count expected=$#
    BATCH_NUMBER=$((BATCH_NUMBER + 1))
    for line in "$@"; do
        if [[ -z "$commands" ]]; then commands="$line"; else commands+="; $line"; fi
    done
    if ! output="$(ssh_exec "$commands")"; then
        echo "ERROR: batch $BATCH_NUMBER SSH failed; no stale entries have been removed." >&2
        exit 1
    fi
    output="${output//$'\r'/}"
    ok_count="$(printf '%s\n' "$output" | grep -c '^SYNC_OK:' || true)"
    if [[ "$ok_count" -ne "$expected" || "$output" == *"SYNC_FAIL:"* || "$output" == *"SYNC_CONFLICT:"* ]]; then
        echo "ERROR: batch $BATCH_NUMBER incomplete: $ok_count/$expected confirmed operations." >&2
        printf '%s\n' "$output" >&2
        echo "Previously installed entries have NOT been cleaned up." >&2
        exit 1
    fi
    PROCESSED=$((PROCESSED + expected))
    echo "Batch $BATCH_NUMBER: $PROCESSED/$TOTAL_COUNT confirmed"
    sleep "$BATCH_PAUSE"
}

echo "Applying $TOTAL_COUNT addresses; batch size=$BATCH_SIZE"
declare -a batch=()
while IFS= read -r command || [[ -n "$command" ]]; do
    [[ -n "$command" ]] || continue
    batch+=("$command")
    if (( ${#batch[@]} >= BATCH_SIZE )); then
        run_batch "${batch[@]}"
        batch=()
    fi
done < "$ROS_SCRIPT"
if (( ${#batch[@]} > 0 )); then run_batch "${batch[@]}"; fi

# Verify only entries owned by THIS synchronization, never raw list size.
COUNT_QUERY="/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\" and comment=\"${GENERATION}\""
NEW_COUNT="$(remote_count "$COUNT_QUERY")" || exit 1
echo "Verified generation entries: $NEW_COUNT/$TOTAL_COUNT"
if (( NEW_COUNT != TOTAL_COUNT )); then
    echo "ERROR: incomplete generation; stale entries retained, no cleanup." >&2
    exit 1
fi

# Cleanup is scoped by our exact ownership prefix, not merely list name. Never
# delete Fail2Ban bans, manually managed addresses, or other feed entries.
CLEANUP_CMD=":do { /ip firewall address-list remove [/ip firewall address-list find where list=\"${ADDRESS_LIST}\" and comment~\"^${OWNER_PREFIX}\" and comment!=\"${GENERATION}\"]; :put \"SYNC_CLEANUP_OK\" } on-error={ :put \"SYNC_CLEANUP_FAIL\" }"
if ! CLEANUP_OUT="$(ssh_exec "$CLEANUP_CMD")"; then
    echo "ERROR: stale-entry cleanup SSH failed; current generation remains active." >&2; exit 1
fi
if [[ "$(printf '%s' "$CLEANUP_OUT" | tr -d '\r[:space:]')" != "SYNC_CLEANUP_OK" ]]; then
    echo "ERROR: cleanup not acknowledged: $CLEANUP_OUT" >&2; exit 1
fi

FINAL_COUNT="$(remote_count "$COUNT_QUERY")" || exit 1
STALE_QUERY="/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\" and comment~\"^${OWNER_PREFIX}\" and comment!=\"${GENERATION}\""
STALE_COUNT="$(remote_count "$STALE_QUERY")" || exit 1
if (( FINAL_COUNT != TOTAL_COUNT || STALE_COUNT != 0 )); then
    echo "ERROR: final verification failed (current=$FINAL_COUNT expected=$TOTAL_COUNT stale=$STALE_COUNT)." >&2
    exit 1
fi

echo "$FEED_NAME synchronization completed successfully"
echo "Source: $SOURCE_URL"
echo "Address list: $ADDRESS_LIST; entries: $FINAL_COUNT; timeout: $TIMEOUT"
echo "Generation: $GENERATION; SSH batches: $BATCH_NUMBER"
printf '===== %s finished %s synchronization for %s =====\n' "$(date -Is)" "$FEED_NAME" "$FWL_HOST"