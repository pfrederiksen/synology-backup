# Synology Backup

[![ClawHub](https://img.shields.io/badge/ClawHub-synology--backup-blue)](https://clawhub.ai/pfrederiksen/synology-backup)
[![Version](https://img.shields.io/badge/version-1.0.4-green)]()

An [OpenClaw](https://openclaw.ai) skill for backing up and restoring OpenClaw workspace, configs, and agent data to a Synology NAS via SMB. Supports Tailscale for secure remote VPS-to-NAS connectivity.

## Features

- 💾 **Full backup** — workspace, configs, agent data, cron jobs
- 🔄 **Snapshot restore** — restore from any previous backup point
- 📊 **Status checks** — mount health, disk space, snapshot inventory
- 🔒 **Tailscale support** — secure remote backup over WireGuard mesh
- ⏰ **Cron scheduling** — automated daily/weekly backups

## Installation

```bash
clawhub install synology-backup
```

## Usage

```bash
bash scripts/status.sh
```

## Requirements

- Synology NAS with SMB share
- OpenClaw installed
- `cifs-utils` for mounting
- Tailscale (optional, for remote backup)

## License

MIT

## Links

- [ClawHub](https://clawhub.ai/pfrederiksen/synology-backup)
- [OpenClaw](https://openclaw.ai)
