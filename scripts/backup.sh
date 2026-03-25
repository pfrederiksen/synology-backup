#!/bin/bash
# Synology Backup — Incremental daily snapshot
# Usage: backup.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SYNOLOGY_BACKUP_CONFIG:-$HOME/.openclaw/synology-backup.json}"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_config "$CONFIG"

TIMESTAMP="$(date +%Y-%m-%d)"
BACKUP_DIR="$MOUNT/backups"
SNAP_DIR="$BACKUP_DIR/$TIMESTAMP"

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would backup to: $SNAP_DIR"
    echo "[DRY RUN] Paths:"
    while IFS= read -r path_raw; do
        path="$(echo "$path_raw" | sed "s|^~|$HOME|")"
        echo "  $path"
    done < <(jq -r '.backupPaths[]' "$CONFIG")
    if [[ "$INCLUDE_SUBAGENT" == "true" ]]; then
        for ws in "$HOME"/.openclaw/workspace-*/; do
            [[ -d "$ws" ]] || continue
            echo "  $ws (sub-agent)"
        done
    fi
    exit 0
fi

# Trap to send Telegram alert on failure
cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        send_telegram "⚠️ Synology backup FAILED on $(hostname) at $(date '+%Y-%m-%d %H:%M PT') — exit code $exit_code"
    fi
}
trap cleanup_on_error EXIT

ensure_mounted

mkdir -p -- "$SNAP_DIR"

backed_up=0
skipped=0

# Backup configured paths
while IFS= read -r path_raw; do
    path="$(echo "$path_raw" | sed "s|^~|$HOME|")"

    if [[ ! -e "$path" ]]; then
        echo "⚠️  Skipping (not found): $path"
        (( skipped++ )) || true
        continue
    fi

    name="$(basename -- "$path")"

    if [[ -d "$path" ]]; then
        rsync -a --delete -- "${path}/" "${SNAP_DIR}/${name}/"
    else
        cp -- "$path" "${SNAP_DIR}/${name}"
    fi
    echo "✓ $name"
    (( backed_up++ )) || true
done < <(jq -r '.backupPaths[]' "$CONFIG")

# Backup sub-agent workspaces
if [[ "$INCLUDE_SUBAGENT" == "true" ]]; then
    for ws in "$HOME"/.openclaw/workspace-*/; do
        [[ -d "$ws" ]] || continue
        name="$(basename -- "$ws")"
        # Allowlist: workspace- prefix, alphanumeric/hyphens/underscores only
        if ! [[ "$name" =~ ^workspace-[a-zA-Z0-9_-]+$ ]]; then
            echo "⚠️  Skipping suspicious workspace name: $name"
            continue
        fi
        rsync -a --delete -- "${ws}" "${SNAP_DIR}/${name}/"
        echo "✓ $name (sub-agent)"
        (( backed_up++ )) || true
    done
fi

# Prune old snapshots
TRASH_DIR="$BACKUP_DIR/.trash"
mkdir -p -- "$TRASH_DIR"
if [[ -d "$BACKUP_DIR" ]]; then
    while IFS= read -r old_snap; do
        [[ -z "$old_snap" ]] && continue
        if [[ "$old_snap" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            mv -- "${BACKUP_DIR}/${old_snap}" "${TRASH_DIR}/${old_snap}" 2>/dev/null \
                && echo "Pruned: $old_snap"
        fi
    done < <(ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r | tail -n +"$((RETENTION + 1))")
fi
# Clean trash older than 3 days
find "$TRASH_DIR" -maxdepth 1 -mindepth 1 -mtime +3 -exec rm -rf -- {} + 2>/dev/null || true

# Write manifest
cat > "${SNAP_DIR}/manifest.json" << MANIFEST
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "snapshot": "$TIMESTAMP",
  "host": "$(hostname)",
  "backed_up": $backed_up,
  "skipped": $skipped
}
MANIFEST

TOTAL_SIZE="$(du -sh -- "$SNAP_DIR" 2>/dev/null | cut -f1)"
SNAP_COUNT="$(ls -1 "$BACKUP_DIR" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' 2>/dev/null || echo 0)"

echo ""
echo "✅ Backup complete: $SNAP_DIR ($TOTAL_SIZE)"
echo "   $backed_up paths backed up, $skipped skipped"
echo "   Snapshots: $SNAP_COUNT (keeping last $RETENTION)"

# Clear error trap — backup succeeded
trap - EXIT
