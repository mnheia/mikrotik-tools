Copyright (c) 2026, Mnheia <mnheia@gmail.com>

# mikrotik-tools
Small Linux/Bash utilities for MikroTik RouterOS administration.

The current scripts synchronize public threat-intelligence feeds into dedicated RouterOS firewall address-lists over SSH.

## Scripts

### threat-feeds/c2intel-sync.sh
Downloads the C2IntelFeeds verified IPv4 C2 feed and synchronizes it to a MikroTik address-list.

Default address-list: `botnet`

Default timeout: `8d`

Recommended schedule: once per day.

### threat-feeds/spamhaus-drop-sync.sh
Downloads the official Spamhaus IPv4 DROP JSON feed, validates the CIDRs and synchronizes them to a MikroTik address-list.

Default address-list: `threat`

Default timeout: `2w1d`

Recommended schedule: once per day or less frequently. Spamhaus asks automated users not to fetch the DROP list more than once per hour.

## Safe update strategy
Both scripts use the same update process:

1. Download and validate the feed locally.
2. Test the SSH connection to RouterOS.
3. Add new entries and refresh existing entries in batches.
4. Mark successfully processed entries with a unique generation.
5. Verify that the complete new generation exists.
6. Only then remove stale entries from the previous generation.
7. Verify the final address-list count.

The live address-list is therefore not cleared before a replacement feed has been imported and verified.

## Requirements
Linux with:

- Bash
- OpenSSH client
- wget
- Python 3
- flock
- standard core utilities

`spamhaus-drop-sync.sh` also requires `jq`.

The RouterOS user must have enough permissions to read and modify `/ip firewall address-list` entries.

## SSH authentication
The public versions use SSH key authentication only. Password files and `sshpass` are not used.

Configure RouterOS SSH access first, then run for example:

```bash
ROUTER_HOST=router.example.net \
ROUTER_USER=automation \
./threat-feeds/c2intel-sync.sh
```

For a non-standard SSH port or a specific private key:

```bash
ROUTER_HOST=router.example.net \
ROUTER_USER=automation \
ROUTER_PORT=2222 \
SSH_IDENTITY=/root/.ssh/mikrotik \
./threat-feeds/spamhaus-drop-sync.sh
```

If `SSH_IDENTITY` is not set, OpenSSH uses the normal SSH agent/default key selection.

## Configuration
Common environment variables:

- `ROUTER_HOST` - MikroTik hostname or IP address. Required.
- `ROUTER_USER` - SSH user. Default: `automation`.
- `ROUTER_PORT` - SSH port. Default: `22`.
- `SSH_IDENTITY` - optional SSH private-key path.
- `ADDRESS_LIST` - RouterOS address-list name.
- `TIMEOUT` - RouterOS address-list timeout.
- `BATCH_SIZE` - number of RouterOS operations sent per SSH command.
- `SOURCE_URL` - feed URL if you intentionally want to override the default source.
- `LOCK_FILE` - local lock-file path.
- `LOG_FILE` - local log-file path.

Each script also exposes its own feed sanity thresholds near the top of the file.

## Important
Use a dedicated RouterOS address-list for each script.

During cleanup, entries in that address-list which are not part of the newly verified generation are removed. Do not mix manually maintained entries into the same list.

The scripts use `StrictHostKeyChecking=accept-new`. Existing changed SSH host keys are still rejected, but a previously unseen host key is accepted automatically. Change that option if your environment requires manual host-key enrollment.

## Feed sources
C2IntelFeeds:

https://github.com/drb-ra/C2IntelFeeds

Spamhaus DROP:

https://www.spamhaus.org/drop/drop_v4.json

Spamhaus describes DROP as a free dataset for network protection. Refer to the Spamhaus website for the current usage and attribution requirements.

## Bugs
Please report bugs or feature requests through the web interface at https://github.com/mnheia/mikrotik-tools/issues
