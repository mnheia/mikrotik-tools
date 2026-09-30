#!/usr/bin/env bash
set -Eeuo pipefail

# Copyright (c) 2026, Mnheia <mnheia@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

#
# C2IntelFeeds verified C2 IPv4 feed -> MikroTik RouterOS
#
# Source:
#   https://github.com/drb-ra/C2IntelFeeds
#   feeds/IPC2s.csv = verified C2 IPs seen in the last 7 days
#
# Safe update strategy:
#   1. Download and validate the feed locally.
#   2. Test MikroTik SSH.
#   3. Add new entries and refresh existing entries in place.
#   4. Mark every successfully processed entry with a unique generation.
#   5. Verify the complete new generation exists.
#   6. Only then remove stale entries from previous generations.
#
# The live botnet list is never cleared before the replacement generation
# has been successfully imported and verified.
#
# Intended to run once per day.
#

LOCK_FILE="${LOCK_FILE:-/run/lock/mikrotik-c2intel-sync.lock}"
LOG_FILE="${LOG_FILE:-/var/log/mikrotik-c2intel-sync.log}"

ROUTER_HOST="${ROUTER_HOST:-router.example.com}"
ROUTER_USER="${ROUTER_USER:-automation}"
ROUTER_PORT="${ROUTER_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"

SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/drb-ra/C2IntelFeeds/master/feeds/IPC2s.csv}"

ADDRESS_LIST="${ADDRESS_LIST:-botnet}"

#
# The feed itself contains C2 IPs observed during the last 7 days.
# Entries are synchronized daily and stale entries are explicitly removed.
# The timeout is therefore primarily a fail-safe if this updater stops running.
#
TIMEOUT="${TIMEOUT:-8d}"

#
# RouterOS operations per SSH command.
# Commands are sent as one semicolon-separated remote command; we do not feed
# multiline RouterOS commands via SSH stdin.
#
BATCH_SIZE="${BATCH_SIZE:-20}"

#
# Feed sanity limits.
# The verified 7-day feed is currently roughly in the low hundreds.
# These limits deliberately leave substantial room for normal variation while
# protecting the router from an upstream format/error explosion.
#
MIN_IPS="${MIN_IPS:-20}"
MAX_IPS="${MAX_IPS:-2000}"


# ----------------------------------------------------------------------
# Configuration check
# ----------------------------------------------------------------------

if [ "$ROUTER_HOST" = "router.example.com" ]; then
    echo "ERROR: set ROUTER_HOST to your MikroTik hostname or IP address." >&2
    exit 1
fi


# ----------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------

exec >>"$LOG_FILE" 2>&1

echo
echo "===== $(date -Is) starting C2IntelFeeds botnet update for ${ROUTER_HOST} ====="


# ----------------------------------------------------------------------
# Lock
# ----------------------------------------------------------------------

exec 200>"$LOCK_FILE"

flock -n 200 || {
    echo "Another C2IntelFeeds botnet update is already running. Exiting."
    exit 0
}


# ----------------------------------------------------------------------
# Required commands
# ----------------------------------------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

need_cmd wget
need_cmd python3
need_cmd ssh
need_cmd sort
need_cmd wc
need_cmd tr
need_cmd flock
need_cmd mktemp

# SSH key authentication only. If SSH_IDENTITY is empty, ssh uses the
# normal agent/default key selection.
SSH_OPTS=(
    -n
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
    -p "$ROUTER_PORT"
)

if [ -n "$SSH_IDENTITY" ]; then
    SSH_OPTS+=( -i "$SSH_IDENTITY" )
fi


# ----------------------------------------------------------------------
# Temporary working directory
# ----------------------------------------------------------------------

WORKDIR="$(mktemp -d)"

RAW_FEED="${WORKDIR}/IPC2s.csv"
IP_LIST="${WORKDIR}/botnet-ipv4.txt"
ROS_SCRIPT="${WORKDIR}/botnet.rsc"

cleanup() {
    rm -rf "$WORKDIR"
}

trap cleanup EXIT


# ----------------------------------------------------------------------
# Download verified C2 feed
# ----------------------------------------------------------------------

echo "Downloading C2IntelFeeds verified C2 IPv4 feed:"
echo "  ${SOURCE_URL}"

wget \
    -q \
    -T 30 \
    --tries=3 \
    -O "$RAW_FEED" \
    "$SOURCE_URL"


if [ ! -s "$RAW_FEED" ]; then
    echo "ERROR: downloaded C2IntelFeeds file is empty." >&2
    exit 1
fi


DOWNLOAD_SIZE="$(wc -c < "$RAW_FEED" | tr -d ' ')"

echo "Download completed."
echo "Downloaded size: ${DOWNLOAD_SIZE} bytes"


# ----------------------------------------------------------------------
# Parse and strictly validate feed structure / IPv4 addresses
#
# Expected format:
#
#   #ip,ioc
#   1.2.3.4,Possible ... C2 IP
#
# The first column must contain a syntactically valid IPv4 address.
# Non-global IPv4 space is intentionally skipped rather than imported.
# This prevents RFC1918, loopback, link-local, CGNAT, documentation and other
# special-use ranges from being inserted into the outbound C2 block list.
# ----------------------------------------------------------------------

echo "Parsing and validating C2IntelFeeds IPv4 addresses"

python3 - "$RAW_FEED" "$IP_LIST" <<'PY'
import csv
import ipaddress
import sys

source_file = sys.argv[1]
output_file = sys.argv[2]

valid = set()
non_global = []
data_rows = 0

with open(source_file, "r", encoding="utf-8-sig", newline="") as f:
    reader = csv.reader(f)

    for line_number, row in enumerate(reader, 1):
        if not row:
            continue

        first = row[0].strip()

        # Expected header/comment line: #ip,ioc
        if first.startswith("#"):
            continue

        data_rows += 1

        if not first:
            print(
                f"ERROR: empty IP field on line {line_number}.",
                file=sys.stderr,
            )
            sys.exit(1)

        try:
            ip = ipaddress.ip_address(first)
        except ValueError as exc:
            print(
                f"ERROR: invalid IP on line {line_number}: {first}: {exc}",
                file=sys.stderr,
            )
            sys.exit(1)

        if ip.version != 4:
            print(
                f"ERROR: non-IPv4 address on line {line_number}: {first}",
                file=sys.stderr,
            )
            sys.exit(1)

        if not ip.is_global:
            non_global.append(str(ip))
            continue

        valid.add(str(ip))

if data_rows == 0:
    print("ERROR: feed contains no data rows.", file=sys.stderr)
    sys.exit(1)

if not valid:
    print("ERROR: feed contains no usable global IPv4 addresses.", file=sys.stderr)
    sys.exit(1)

sorted_ips = sorted(valid, key=lambda value: int(ipaddress.ip_address(value)))

with open(output_file, "w", encoding="utf-8") as f:
    for ip in sorted_ips:
        f.write(ip + "\n")

print(f"Feed data rows:                 {data_rows}")
print(f"Unique global IPv4 addresses:  {len(sorted_ips)}")
print(f"Skipped non-global IPv4:       {len(non_global)}")

if non_global:
    print("Skipped non-global addresses:  " + ", ".join(sorted(set(non_global))))
PY


# ----------------------------------------------------------------------
# Count / sanity check
# ----------------------------------------------------------------------

TOTAL_COUNT="$(wc -l < "$IP_LIST" | tr -d ' ')"

echo "C2IntelFeeds usable IPv4 addresses found: ${TOTAL_COUNT}"


if [ "$TOTAL_COUNT" -lt "$MIN_IPS" ]; then
    echo
    echo "ERROR: suspiciously small C2IntelFeeds list."
    echo "Minimum expected: ${MIN_IPS}"
    echo "Received:         ${TOTAL_COUNT}"
    echo
    echo "MikroTik has NOT been modified."
    exit 1
fi


if [ "$TOTAL_COUNT" -gt "$MAX_IPS" ]; then
    echo
    echo "ERROR: suspiciously large C2IntelFeeds list."
    echo "Maximum expected: ${MAX_IPS}"
    echo "Received:         ${TOTAL_COUNT}"
    echo
    echo "MikroTik has NOT been modified."
    exit 1
fi


# ----------------------------------------------------------------------
# Generation marker
# ----------------------------------------------------------------------

GENERATION="c2intel-$(date -u +%Y%m%dT%H%M%SZ)-$$"

echo "Generation: ${GENERATION}"


# ----------------------------------------------------------------------
# Build RouterOS command list
#
# RouterOS does not allow duplicate addresses in the same address-list.
# Each operation therefore attempts ADD first. If the address already exists,
# the on-error handler refreshes the timeout and marks the existing entry as
# belonging to this generation.
# ----------------------------------------------------------------------

echo
echo "Building RouterOS command list"

while IFS= read -r ip; do

    [ -z "$ip" ] && continue

    printf ':do { /ip firewall address-list add list="%s" address="%s" timeout=%s comment="%s" } on-error={ /ip firewall address-list set [find where list="%s" && address="%s"] timeout=%s comment="%s" }\n' \
        "$ADDRESS_LIST" \
        "$ip" \
        "$TIMEOUT" \
        "$GENERATION" \
        "$ADDRESS_LIST" \
        "$ip" \
        "$TIMEOUT" \
        "$GENERATION"

done < "$IP_LIST" > "$ROS_SCRIPT"


SCRIPT_COUNT="$(wc -l < "$ROS_SCRIPT" | tr -d ' ')"

echo "RouterOS commands generated: ${SCRIPT_COUNT}"


if [ "$SCRIPT_COUNT" -ne "$TOTAL_COUNT" ]; then
    echo "ERROR: RouterOS command count does not match IP count." >&2
    exit 1
fi


# ----------------------------------------------------------------------
# Test MikroTik SSH BEFORE modifying anything
# ----------------------------------------------------------------------

echo
echo "Testing SSH connection to ${ROUTER_HOST}"

SSH_TEST="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        ':put "c2intel-test-ok"' \
        2>&1
)"


if [[ "$SSH_TEST" != *"c2intel-test-ok"* ]]; then
    echo "ERROR: MikroTik SSH test failed." >&2
    echo "$SSH_TEST"
    exit 1
fi


echo "MikroTik SSH connection OK"


# ----------------------------------------------------------------------
# Check existing list count
# ----------------------------------------------------------------------

echo
echo "Checking current MikroTik ${ADDRESS_LIST} list"

REMOTE_BEFORE="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\"" \
        | tr -d '\r[:space:]'
)"


if [[ ! "$REMOTE_BEFORE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid current MikroTik address-list count:"
    echo "$REMOTE_BEFORE"
    exit 1
fi


echo "Existing ${ADDRESS_LIST} entries: ${REMOTE_BEFORE}"


# ----------------------------------------------------------------------
# Execute RouterOS updates in small SSH batches
#
# Existing entries remain active throughout the update.
# No stale entry is removed until the complete current generation has been
# verified on the router.
# ----------------------------------------------------------------------

echo
echo "Synchronizing ${TOTAL_COUNT} C2 IPv4 addresses"
echo "SSH batch size: ${BATCH_SIZE}"

BATCH=""
BATCH_COMMANDS=0
BATCH_NUMBER=0
PROCESSED=0


run_routeros_batch() {

    local commands="$1"
    local command_count="$2"
    local marker
    local output
    local rc

    BATCH_NUMBER=$((BATCH_NUMBER + 1))
    marker="c2intel-batch-${BATCH_NUMBER}-ok"

    set +e

    output="$(
        ssh "${SSH_OPTS[@]}" \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=4 \
            "${ROUTER_USER}@${ROUTER_HOST}" \
            "${commands}; :put \"${marker}\"" \
            2>&1
    )"

    rc=$?

    set -e


    if [ "$rc" -ne 0 ]; then
        echo
        echo "ERROR: SSH batch ${BATCH_NUMBER} failed."
        echo "SSH exit code: ${rc}"
        echo "$output"
        echo
        echo "Old MikroTik botnet entries have NOT been removed."
        exit 1
    fi


    if [[ "$output" != *"$marker"* ]]; then
        echo
        echo "ERROR: RouterOS batch ${BATCH_NUMBER} did not complete."
        echo "$output"
        echo
        echo "Old MikroTik botnet entries have NOT been removed."
        exit 1
    fi


    PROCESSED=$((PROCESSED + command_count))

    echo "Batch ${BATCH_NUMBER}: ${PROCESSED}/${TOTAL_COUNT} IPs processed"
}


while IFS= read -r command; do

    [ -z "$command" ] && continue

    if [ -z "$BATCH" ]; then
        BATCH="$command"
    else
        BATCH="${BATCH}; ${command}"
    fi

    BATCH_COMMANDS=$((BATCH_COMMANDS + 1))


    if [ "$BATCH_COMMANDS" -ge "$BATCH_SIZE" ]; then
        run_routeros_batch "$BATCH" "$BATCH_COMMANDS"

        BATCH=""
        BATCH_COMMANDS=0
    fi

done < "$ROS_SCRIPT"


# Send final partial batch.
if [ "$BATCH_COMMANDS" -gt 0 ]; then
    run_routeros_batch "$BATCH" "$BATCH_COMMANDS"
fi


echo
echo "All RouterOS update batches completed"


# ----------------------------------------------------------------------
# Verify new generation BEFORE removing stale entries
# ----------------------------------------------------------------------

echo
echo "Verifying new C2IntelFeeds generation"

REMOTE_CURRENT="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\" && comment=\"${GENERATION}\"" \
        | tr -d '\r[:space:]'
)"


if [[ ! "$REMOTE_CURRENT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid MikroTik generation count:"
    echo "$REMOTE_CURRENT"
    echo
    echo "Stale botnet entries have NOT been removed."
    exit 1
fi


echo "Feed IPv4 addresses:       ${TOTAL_COUNT}"
echo "Current generation entries: ${REMOTE_CURRENT}"


if [ "$REMOTE_CURRENT" -ne "$TOTAL_COUNT" ]; then
    echo
    echo "ERROR: new C2IntelFeeds generation is incomplete."
    echo
    echo "Feed:       ${TOTAL_COUNT}"
    echo "Generation: ${REMOTE_CURRENT}"
    echo
    echo "Stale botnet entries have NOT been removed."
    echo "Existing botnet protection remains in place."
    exit 1
fi


echo "New generation verified successfully"


# ----------------------------------------------------------------------
# Remove stale entries
#
# The botnet address-list is owned exclusively by this updater.
# This is the ONLY point at which old entries are removed.
# ----------------------------------------------------------------------

echo
echo "Removing stale C2IntelFeeds botnet entries"

CLEANUP_MARKER="c2intel-cleanup-ok"

set +e

CLEANUP_OUTPUT="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list remove [find where list=\"${ADDRESS_LIST}\" && comment!=\"${GENERATION}\"]; :put \"${CLEANUP_MARKER}\"" \
        2>&1
)"

CLEANUP_RC=$?

set -e


if [ "$CLEANUP_RC" -ne 0 ]; then
    echo "ERROR: stale-entry cleanup failed."
    echo "$CLEANUP_OUTPUT"
    echo
    echo "The new generation remains installed."
    echo "Some stale entries may also remain."
    exit 1
fi


if [[ "$CLEANUP_OUTPUT" != *"$CLEANUP_MARKER"* ]]; then
    echo "ERROR: stale-entry cleanup did not complete."
    echo "$CLEANUP_OUTPUT"
    echo
    echo "The new generation remains installed."
    echo "Some stale entries may also remain."
    exit 1
fi


echo "Stale entries removed successfully"


# ----------------------------------------------------------------------
# Final remote verification
# ----------------------------------------------------------------------

echo
echo "Checking final ${ADDRESS_LIST} address-list count"

REMOTE_AFTER="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\"" \
        | tr -d '\r[:space:]'
)"


if [[ ! "$REMOTE_AFTER" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid final MikroTik address-list count:"
    echo "$REMOTE_AFTER"
    exit 1
fi


echo "C2IntelFeeds IPv4 addresses: ${TOTAL_COUNT}"
echo "MikroTik list entries:       ${REMOTE_AFTER}"


if [ "$REMOTE_AFTER" -ne "$TOTAL_COUNT" ]; then
    echo
    echo "ERROR: final MikroTik address-list count does not match feed."
    echo
    echo "Feed:     ${TOTAL_COUNT}"
    echo "MikroTik: ${REMOTE_AFTER}"
    exit 1
fi


# ----------------------------------------------------------------------
# Success
# ----------------------------------------------------------------------

echo
echo "C2IntelFeeds botnet synchronization completed successfully"
echo
echo "Source:       ${SOURCE_URL}"
echo "Address list: ${ADDRESS_LIST}"
echo "IPv4 entries: ${TOTAL_COUNT}"
echo "Timeout:      ${TIMEOUT}"
echo "Generation:   ${GENERATION}"
echo "SSH batches:  ${BATCH_NUMBER}"
echo
echo "===== $(date -Is) finished C2IntelFeeds botnet update for ${ROUTER_HOST} ====="
