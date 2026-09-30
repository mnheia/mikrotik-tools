#!/usr/bin/env bash
set -Eeuo pipefail

# Copyright (c) 2026, Mnheia <mnheia@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

#
# Spamhaus DROP -> MikroTik RouterOS
#
# Downloads the official Spamhaus IPv4 DROP feed,
# validates all CIDRs on Linux, and synchronizes them
# into a dynamic MikroTik address-list.
#
# Safe update strategy:
#   1. Download and validate feed locally.
#   2. Test MikroTik SSH.
#   3. Add new entries and refresh existing entries in-place.
#   4. Mark every successfully refreshed entry with a unique generation.
#   5. Verify that the complete new generation exists.
#   6. Only then remove stale entries from previous generations.
#
# The live address-list is never deleted before the replacement
# generation has been fully imported and verified.
#
# Intended to run once per week.
#

LOCK_FILE="${LOCK_FILE:-/run/lock/mikrotik-spamhaus-drop-sync.lock}"
LOG_FILE="${LOG_FILE:-/var/log/mikrotik-spamhaus-drop-sync.log}"

ROUTER_HOST="${ROUTER_HOST:-router.example.com}"
ROUTER_USER="${ROUTER_USER:-automation}"
ROUTER_PORT="${ROUTER_PORT:-22}"
SSH_IDENTITY="${SSH_IDENTITY:-}"

SOURCE_URL="${SOURCE_URL:-https://www.spamhaus.org/drop/drop_v4.json}"

ADDRESS_LIST="${ADDRESS_LIST:-threat}"

#
# 15 days = 2 weeks + 1 day.
#
# Using a timeout makes the entries dynamic.
# RouterOS stores timeout-based address-list entries in RAM,
# not permanently on disk.
#
TIMEOUT="${TIMEOUT:-2w1d}"

#
# Number of RouterOS address-list operations sent in one SSH command.
# RouterOS SSH does not support feeding multiline commands via stdin,
# so commands are sent as a single remote command separated by ';'.
#
BATCH_SIZE="${BATCH_SIZE:-20}"

#
# Sanity limits.
#
# Current Spamhaus DROP is normally comfortably within this range.
#
MIN_CIDRS="${MIN_CIDRS:-500}"
MAX_CIDRS="${MAX_CIDRS:-5000}"


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
echo "===== $(date -Is) starting Spamhaus DROP update for ${ROUTER_HOST} ====="


# ----------------------------------------------------------------------
# Lock
# ----------------------------------------------------------------------

exec 200>"$LOCK_FILE"

flock -n 200 || {
    echo "Another Spamhaus DROP update is already running. Exiting."
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
need_cmd jq
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

RAW_LIST="${WORKDIR}/spamhaus-drop.json"
CIDR_LIST="${WORKDIR}/spamhaus-drop-ipv4.txt"
ROS_SCRIPT="${WORKDIR}/spamhaus-drop.rsc"

cleanup() {
    rm -rf "$WORKDIR"
}

trap cleanup EXIT


# ----------------------------------------------------------------------
# Download Spamhaus DROP
# ----------------------------------------------------------------------

echo "Downloading Spamhaus DROP:"
echo "  ${SOURCE_URL}"

wget \
    -q \
    -T 30 \
    --tries=3 \
    -O "$RAW_LIST" \
    "$SOURCE_URL"


if [ ! -s "$RAW_LIST" ]; then
    echo "ERROR: downloaded Spamhaus DROP file is empty." >&2
    exit 1
fi


DOWNLOAD_SIZE="$(wc -c < "$RAW_LIST" | tr -d ' ')"

echo "Download completed."
echo "Downloaded size: ${DOWNLOAD_SIZE} bytes"


# ----------------------------------------------------------------------
# Validate JSON stream
# ----------------------------------------------------------------------

echo "Validating Spamhaus JSON feed"

if ! jq empty "$RAW_LIST" >/dev/null 2>&1; then
    echo "ERROR: downloaded Spamhaus file contains invalid JSON." >&2
    exit 1
fi


# ----------------------------------------------------------------------
# Extract DROP CIDRs
#
# Spamhaus publishes actual DROP entries with:
#
#   .type == null
#   .cidr
#
# Metadata objects are ignored.
# ----------------------------------------------------------------------

echo "Extracting IPv4 DROP CIDRs"

jq -r '
    select(.type == null)
    | select(.cidr != null)
    | .cidr
' "$RAW_LIST" \
    | sort -u \
    > "$CIDR_LIST"


if [ ! -s "$CIDR_LIST" ]; then
    echo "ERROR: no IPv4 CIDRs extracted from Spamhaus feed." >&2
    exit 1
fi


# ----------------------------------------------------------------------
# Strict IPv4 CIDR validation
# ----------------------------------------------------------------------

echo "Validating IPv4 CIDRs"

python3 - "$CIDR_LIST" <<'PY'
import ipaddress
import sys

filename = sys.argv[1]
count = 0

with open(filename, "r", encoding="utf-8") as f:
    for line_number, line in enumerate(f, 1):
        cidr = line.strip()

        if not cidr:
            continue

        try:
            network = ipaddress.ip_network(cidr, strict=True)
        except ValueError as exc:
            print(
                f"ERROR: invalid CIDR on line {line_number}: "
                f"{cidr}: {exc}",
                file=sys.stderr,
            )
            sys.exit(1)

        if network.version != 4:
            print(
                f"ERROR: non-IPv4 network on line "
                f"{line_number}: {cidr}",
                file=sys.stderr,
            )
            sys.exit(1)

        count += 1

if count == 0:
    print("ERROR: no valid IPv4 networks found.", file=sys.stderr)
    sys.exit(1)

print(f"Validated IPv4 CIDRs: {count}")
PY


# ----------------------------------------------------------------------
# Count / sanity check
# ----------------------------------------------------------------------

TOTAL_COUNT="$(wc -l < "$CIDR_LIST" | tr -d ' ')"

echo "Spamhaus IPv4 DROP CIDRs found: ${TOTAL_COUNT}"


if [ "$TOTAL_COUNT" -lt "$MIN_CIDRS" ]; then
    echo
    echo "ERROR: suspiciously small Spamhaus DROP list."
    echo "Minimum expected: ${MIN_CIDRS}"
    echo "Received:         ${TOTAL_COUNT}"
    echo
    echo "MikroTik has NOT been modified."
    exit 1
fi


if [ "$TOTAL_COUNT" -gt "$MAX_CIDRS" ]; then
    echo
    echo "ERROR: suspiciously large Spamhaus DROP list."
    echo "Maximum expected: ${MAX_CIDRS}"
    echo "Received:         ${TOTAL_COUNT}"
    echo
    echo "MikroTik has NOT been modified."
    exit 1
fi


# ----------------------------------------------------------------------
# Generation marker
#
# Every entry successfully processed during this run receives the same
# comment. Stale entries retain an older/blank comment and are removed
# only after the new generation has been fully verified.
# ----------------------------------------------------------------------

GENERATION="spamhaus-drop-$(date -u +%Y%m%dT%H%M%SZ)-$$"

echo "Generation: ${GENERATION}"


# ----------------------------------------------------------------------
# Build RouterOS command list
#
# RouterOS does not allow duplicate addresses in the same address-list.
# Therefore each command tries ADD first. If the address already exists,
# the on-error handler refreshes that existing entry's timeout and comment.
#
# Every line is later joined into a small semicolon-separated SSH batch.
# No multiline script is sent through SSH stdin.
# ----------------------------------------------------------------------

echo
echo "Building RouterOS command list"

while IFS= read -r cidr; do

    [ -z "$cidr" ] && continue

    printf ':do { /ip firewall address-list add list="%s" address="%s" timeout=%s comment="%s" } on-error={ /ip firewall address-list set [find where list="%s" and address="%s"] timeout=%s comment="%s" }\n' \
        "$ADDRESS_LIST" \
        "$cidr" \
        "$TIMEOUT" \
        "$GENERATION" \
        "$ADDRESS_LIST" \
        "$cidr" \
        "$TIMEOUT" \
        "$GENERATION"

done < "$CIDR_LIST" > "$ROS_SCRIPT"


SCRIPT_COUNT="$(wc -l < "$ROS_SCRIPT" | tr -d ' ')"

echo "RouterOS commands generated: ${SCRIPT_COUNT}"


if [ "$SCRIPT_COUNT" -ne "$TOTAL_COUNT" ]; then
    echo "ERROR: RouterOS command count does not match CIDR count." >&2
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
        ':put "spamhaus-test-ok"' \
        2>&1
)"


if [[ "$SSH_TEST" != *"spamhaus-test-ok"* ]]; then
    echo "ERROR: MikroTik SSH test failed." >&2
    echo "$SSH_TEST"
    exit 1
fi


echo "MikroTik SSH connection OK"


# ----------------------------------------------------------------------
# Check existing list count
# ----------------------------------------------------------------------

echo
echo "Checking current MikroTik list"

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
# Execute RouterOS commands in small SSH batches
#
# IMPORTANT:
#
# We do NOT delete the existing list first.
#
# Existing CIDRs are refreshed in place.
# New CIDRs are added.
# Old/stale CIDRs remain active until the new generation is verified.
# ----------------------------------------------------------------------

echo
echo "Synchronizing ${TOTAL_COUNT} Spamhaus CIDRs"
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

    marker="spamhaus-batch-${BATCH_NUMBER}-ok"

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
        echo "Old MikroTik entries have NOT been removed."
        exit 1
    fi


    if [[ "$output" != *"$marker"* ]]; then
        echo
        echo "ERROR: RouterOS batch ${BATCH_NUMBER} did not complete."
        echo "$output"
        echo
        echo "Old MikroTik entries have NOT been removed."
        exit 1
    fi


    PROCESSED=$((PROCESSED + command_count))

    echo "Batch ${BATCH_NUMBER}: ${PROCESSED}/${TOTAL_COUNT} CIDRs processed"
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
# Verify new generation BEFORE deleting stale entries
# ----------------------------------------------------------------------

echo
echo "Verifying new Spamhaus generation"

REMOTE_CURRENT="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list print count-only where list=\"${ADDRESS_LIST}\" and comment=\"${GENERATION}\"" \
        | tr -d '\r[:space:]'
)"


if [[ ! "$REMOTE_CURRENT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid MikroTik generation count:"
    echo "$REMOTE_CURRENT"
    echo
    echo "Stale address-list entries have NOT been removed."
    exit 1
fi


echo "Spamhaus feed CIDRs:        ${TOTAL_COUNT}"
echo "Current generation entries: ${REMOTE_CURRENT}"


if [ "$REMOTE_CURRENT" -ne "$TOTAL_COUNT" ]; then
    echo
    echo "ERROR: new Spamhaus generation is incomplete."
    echo
    echo "Feed:       ${TOTAL_COUNT}"
    echo "Generation: ${REMOTE_CURRENT}"
    echo
    echo "Stale address-list entries have NOT been removed."
    echo "Existing firewall protection remains in place."
    exit 1
fi


echo "New generation verified successfully"


# ----------------------------------------------------------------------
# Remove stale entries
#
# THIS IS THE ONLY POINT where old entries are removed.
#
# At this point every current Spamhaus CIDR has already been imported or
# refreshed and marked with the current generation.
# ----------------------------------------------------------------------

echo
echo "Removing stale Spamhaus entries"

CLEANUP_MARKER="spamhaus-cleanup-ok"

set +e

CLEANUP_OUTPUT="$(
    ssh "${SSH_OPTS[@]}" \
        "${ROUTER_USER}@${ROUTER_HOST}" \
        "/ip firewall address-list remove [find where list=\"${ADDRESS_LIST}\" and comment!=\"${GENERATION}\"]; :put \"${CLEANUP_MARKER}\"" \
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


echo "Spamhaus feed CIDRs:   ${TOTAL_COUNT}"
echo "MikroTik list entries: ${REMOTE_AFTER}"


if [ "$REMOTE_AFTER" -ne "$TOTAL_COUNT" ]; then
    echo
    echo "ERROR: final MikroTik address-list count does not match Spamhaus feed."
    echo
    echo "Feed:     ${TOTAL_COUNT}"
    echo "MikroTik: ${REMOTE_AFTER}"
    exit 1
fi


# ----------------------------------------------------------------------
# Success
# ----------------------------------------------------------------------

echo
echo "Spamhaus DROP synchronization completed successfully"
echo
echo "Source:       ${SOURCE_URL}"
echo "Address list: ${ADDRESS_LIST}"
echo "CIDRs:        ${TOTAL_COUNT}"
echo "Timeout:      ${TIMEOUT}"
echo "Generation:   ${GENERATION}"
echo "SSH batches:  ${BATCH_NUMBER}"
echo
echo "===== $(date -Is) finished Spamhaus DROP update for ${ROUTER_HOST} ====="
