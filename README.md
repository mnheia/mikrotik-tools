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


### fail2ban/mikrotik-fail2ban.sh
Small SSH wrapper intended for Fail2ban actions that need to execute a RouterOS command on a MikroTik device.

The public version uses SSH key authentication only and supports the same common connection variables as the threat-feed scripts:

- `ROUTER_HOST`
- `ROUTER_USER`
- `ROUTER_PORT`
- `SSH_IDENTITY`
- `LOCK`
- `LOG`

Example:

```bash
ROUTER_HOST=router.example.net \\
ROUTER_USER=automation \\
./fail2ban/mikrotik-fail2ban.sh '/ip firewall address-list add list=fail2ban address=198.51.100.25 timeout=1d'
```

The exact RouterOS command is supplied by the caller, so Fail2ban can use the helper from a custom action without storing a router password locally.


Example Fail2ban configuration is included under `fail2ban/examples/`:

- `mikrotik.conf` provides an `action.d` definition that adds banned IPs to a dedicated RouterOS `fail2ban` address-list with a one-day timeout.
- `apache.conf` shows several Apache/PHP jails using `action = mikrotik`.

The example intentionally leaves `actionunban` empty because RouterOS removes the address-list entry automatically when its timeout expires. Keep Fail2ban in a dedicated address-list rather than sharing a list managed by a feed synchronization script. Adjust the helper path, address-list name and timeout to match your installation.



Example Fail2ban configuration is included under `fail2ban/action.d/` and `fail2ban/jail.d/`.

A typical installation is:

```bash
install -m 0750 fail2ban/mikrotik-fail2ban.sh /usr/local/sbin/mikrotik-fail2ban.sh
cp fail2ban/action.d/mikrotik.conf.example /etc/fail2ban/action.d/mikrotik.conf
cp fail2ban/jail.d/apache.conf.example /etc/fail2ban/jail.d/apache.conf
fail2ban-client -t
systemctl reload fail2ban
```

The example action adds banned addresses to the RouterOS `threat` address-list with a one-day timeout. Because RouterOS expires the entry itself, `actionunban` is intentionally empty. Adjust the list name and timeout to match your firewall policy.


### certificates/letsencrypt-sync.sh
Renews a Let's Encrypt certificate with Certbot webroot authentication and synchronizes the certificate to MikroTik RouterOS over SSH when the certificate changes.

The workflow is:

1. Test the RouterOS SSH connection.
2. Temporarily enable a RouterOS NAT rule identified by a configurable comment.
3. Run Certbot with webroot HTTP-01 validation.
4. Disable the temporary NAT rule.
5. Compare the local certificate fingerprint before and after the Certbot run.
6. If the certificate changed, upload `fullchain.pem` and `privkey.pem`.
7. Run the RouterOS `CertificateImport` system script.
8. The RouterOS script imports the certificate/key and removes the temporary uploaded files.

If the certificate did not change, upload/import is skipped. Set `FORCE_IMPORT=1` to upload the existing certificate anyway.

Required configuration:

- `ROUTER_HOST`
- `DOMAIN`
- `WEBROOT`

Optional configuration:

- `ROUTER_USER` (default: `automation`)
- `ROUTER_PORT` (default: `22`)
- `SSH_IDENTITY`
- `CERT_DIR` (default: `/etc/letsencrypt/live/$DOMAIN`)
- `NAT_RULE_COMMENT` (default: `letsencrypt-webroot`)
- `IMPORT_SCRIPT` (default: `CertificateImport`)
- `LOCK`
- `LOG`

Example:

```bash
ROUTER_HOST=router.example.net \
DOMAIN=router.example.net \
WEBROOT=/var/www/router.example.net \
SSH_IDENTITY=/root/.ssh/mikrotik \
./certificates/letsencrypt-sync.sh
```

The public version uses SSH key authentication only.

The `certificates/examples/` directory contains:

- `CertificateImport.rsc` with the RouterOS commands expected by the Linux helper.
- `nat-rule.rsc` with an example disabled HTTP dst-nat rule identified by the `letsencrypt-webroot` comment.

Review the example NAT rule and adapt its addresses/interfaces before use.

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
