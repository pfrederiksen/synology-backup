---
name: synology-backup
description: "Backup and restore OpenClaw workspace, configs, and agent data to a Synology NAS via SMB or SSH/rsync. Use when: backing up workspace files, restoring from a snapshot, checking backup status/health, verifying backup integrity, or setting up automated daily backups. Supports Tailscale for secure remote VPS-to-NAS connectivity. Sends Telegram alert on failure."
tags: ["backup", "synology", "nas", "smb", "rsync", "disaster-recovery", "tailscale"]
---

# Synology Backup

Backup OpenClaw data to a Synology NAS over SMB or SSH/rsync. Designed for secure, automated daily snapshots with configurable retention, integrity verification, and failure alerting.

## Setup

### 1. Network Connectivity

For VPS-to-NAS backups, use [Tailscale](https://tailscale.com) for secure connectivity without exposing SMB to the internet:

1. Install Tailscale on the Synology (Package Center → search "Tailscale")
2. Install Tailscale on the VPS — see [Tailscale's official install guide](https://tailscale.com/download) for your platform
3. Join both to the same tailnet
4. Use the Synology's Tailscale IP in config

For local network setups, use the NAS local IP directly.

### 2. Synology Preparation

1. Create a dedicated user on the Synology (e.g., `openclaw-backup`) with minimal permissions
2. Create or choose a shared folder (e.g., `backups`)
3. Grant the user read/write access to **only** that folder — not admin access

### 3. Credentials File (SMB transport)

Create an SMB credentials file with restricted permissions — **never store credentials in config or scripts**:

```bash
touch ~/.openclaw/.smb-credentials
chmod 600 ~/.openclaw/.smb-credentials
# Add two lines:
# username=<your-synology-user>
# password=<your-synology-password>
```

### 4. Configuration

Create `~/.openclaw/synology-backup.json`:

```json
{
  "host": "100.x.x.x",
  "share": "backups/openclaw",
  "mountPoint": "/mnt/synology",
  "credentialsFile": "~/.openclaw/.smb-credentials",
  "smbVersion": "3.0",
  "transport": "smb",
  "telegramTarget": "-100xxxxxxxxxx",
  "notifyOnSuccess": false,
  "backupPaths": [
    "~/.openclaw/workspace",
    "~/.openclaw/openclaw.json",
    "~/.openclaw/cron",
    "~/.openclaw/agents"
  ],
  "backupExclude": [],
  "includeSubAgentWorkspaces": true,
  "retention": 7,
  "preRestoreRetention": 3,
  "schedule": "0 3 * * *"
}
```

**SSH transport (alternative):** Set `"transport": "ssh"` and add `"sshUser": "your-user"`. No credentials file needed — uses SSH key auth. Requires rsync + SSH access to the Synology.

**Sensitive files:** The `.env` file (containing API keys) is not included by default. Add `"~/.openclaw/.env"` to `backupPaths` only if your NAS share has restricted access.

| Field | Description | Default |
|-------|-------------|---------|
| `host` | Synology IP (Tailscale or local) | required |
| `share` | SMB share path | required |
| `mountPoint` | Local mount point | `/mnt/synology` |
| `credentialsFile` | Path to SMB credentials file | required (SMB) |
| `smbVersion` | SMB protocol version | `3.0` |
| `transport` | `smb` or `ssh` | `smb` |
| `sshUser` | SSH username | required (SSH) |
| `telegramTarget` | Telegram target for failure alerts | your group/chat ID |
| `backupPaths` | Paths to backup | workspace + config |
| `includeSubAgentWorkspaces` | Auto-include `workspace-*` dirs | `true` |
| `retention` | Days of daily snapshots to keep | `7` |
| `preRestoreRetention` | Days to keep pre-restore safety snapshots | `3` |
| `backupExclude` | rsync exclude patterns (`.git/`, `node_modules/` always excluded) | `[]` |
| `notifyOnSuccess` | Send Telegram on successful backup (in addition to failures) | `false` |
| `schedule` | Cron expression (host timezone) | `0 3 * * *` |
| `sshUser` | SSH username (required for ssh transport) | — |
| `sshHost` | SSH hostname (defaults to `host`) | — |
| `sshPort` | SSH port | `22` |
| `sshDest` | Remote backup directory path (required for ssh transport) | — |

### 5. Install Dependencies

```bash
apt-get install -y cifs-utils rsync
```

### 6. Register the Backup Cron

```bash
openclaw cron add \
  --name "Synology Backup" \
  --schedule "0 3 * * *" \
  --tz "America/Los_Angeles" \
  --message "Run the daily Synology backup: bash ~/.openclaw/workspace/skills/synology-backup/scripts/backup.sh && bash ~/.openclaw/workspace/skills/synology-backup/scripts/verify.sh. If backup fails, it will automatically send a Telegram alert. Reply NO_REPLY."
```

## Usage

### Backup Now

```bash
scripts/backup.sh
```

Runs an incremental backup. Add `--dry-run` to preview what would be backed up without touching anything.

### Check Status

```bash
scripts/status.sh
```

Shows mount health, last backup time, snapshot count, total size, and pre-restore safety snapshots.

### Verify Integrity

```bash
scripts/verify.sh          # verify latest snapshot
scripts/verify.sh 2026-03-25  # verify specific date
```

Checksums key files and counts directory contents against the snapshot to confirm data integrity.

### Restore a Snapshot

```bash
scripts/restore.sh          # list available snapshots
scripts/restore.sh 2026-03-25   # restore from specific date
```

Before restoring, automatically saves a **pre-restore safety snapshot** of your current state. If the restore goes wrong, restore the safety snapshot to undo.

## What Gets Backed Up

- `~/.openclaw/workspace/` — memory, SOUL, AGENTS, skills, all workspace files
- `~/.openclaw/workspace-*/` — all sub-agent workspaces (if enabled)
- `~/.openclaw/openclaw.json` — main config
- `~/.openclaw/cron/` — cron job definitions
- `~/.openclaw/agents/` — agent configurations
- `~/.openclaw/.env` — **opt-in only** (contains API keys)

## Snapshot Structure

```
backups/
├── 2026-03-25/
│   ├── manifest.json          # timestamp, host, path counts
│   ├── workspace/
│   ├── workspace-news/
│   ├── agents/
│   ├── cron/
│   └── openclaw.json
├── pre-restore-2026-03-25-143022/   # safety snapshot before restore
├── 2026-03-24/
└── ...
```

## Failure Alerting

If a backup fails for any reason, a Telegram alert is sent automatically:

> ⚠️ Synology backup FAILED on <hostname> at <date> — exit code 1

Configure the target via `telegramTarget` in the config.

## Security Notes

- **Credentials**: Always use a dedicated credentials file with `chmod 600`. Never inline secrets in config, scripts, or fstab.
- **Network**: Use Tailscale or a VPN for remote backups. Never expose SMB (port 445) to the public internet.
- **Sensitive data**: `.env` is excluded by default. Only include it if your NAS is properly secured.
- **NAS user**: Dedicated user with access to only the backup share — not an admin account.
- **Input validation**: All config values are validated before use — no shell injection possible via host, share, mount, or path fields.
- **Path allowlist**: Restore uses an explicit allowlist (`workspace`, `cron`, `agents`, `openclaw.json`, `.env`) — no arbitrary path writes.

## System Access

**Files read:** `~/.openclaw/synology-backup.json`, `~/.openclaw/.smb-credentials`
**Files written:** Synology NAS share (via SMB mount or SSH/rsync), `manifest.json` in each snapshot
**Network:** SMB (port 445) or SSH (port 22) to Synology NAS IP only
**Commands used:** `mount`, `rsync`, `cp`, `find`, `du`, `df`, `md5sum`, `jq`, `openclaw message send`
