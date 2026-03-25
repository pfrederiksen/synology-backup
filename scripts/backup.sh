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

# Build exclude args once for display in dry-run
mapfile -t EXCLUDE_ARGS < <(build_exclude_args)

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Transport:  $TRANSPORT"
    if [[ "$TRANSPORT" == "ssh" ]]; then
        echo "[DRY RUN] Destination: ${SSH_USER}@${SSH_HOST}:${SSH_DEST}/backups/$TIMESTAMP"
    else
        echo "[DRY RUN] Destination: $SNAP_DIR"
    fi
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
    echo "[DRY RUN] Excludes: ${EXCLUDE_ARGS[*]}"
    echo "[DRY RUN] Retention: $RETENTION days (pre-restore: $PRE_RESTORE_RETENTION days)"
    exit 0
fi

# Trap: alert on failure (rsync 24 = vanished files = benign, not a real error)
cleanup_on_error() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && $exit_code -ne 24 ]]; then
        send_telegram "⚠️ Synology backup FAILED on $(hostname) — exit code $exit_code"
    fi
}
trap cleanup_on_error EXIT

ensure_mounted

if [[ "$TRANSPORT" == "smb" ]]; then
    mkdir -p -- "$SNAP_DIR"
fi

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
        if [[ "$TRANSPORT" == "ssh" ]]; then
            rsync -a --delete -e "ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
                "${EXCLUDE_ARGS[@]}" -- \
                "${path}/" "$(remote_path "backups/$TIMESTAMP/$name/")"
        else
            rsync -a --delete "${EXCLUDE_ARGS[@]}" -- "${path}/" "${SNAP_DIR}/${name}/"
        fi
    else
        if [[ "$TRANSPORT" == "ssh" ]]; then
            rsync -a -e "ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new"                 -- "$path" "$(remote_path "backups/$TIMESTAMP/$name")"
        else
            cp -- "$path" "${SNAP_DIR}/${name}"
        fi
    fi
    echo "✓ $name"
    (( backed_up++ )) || true
done < <(jq -r '.backupPaths[]' "$CONFIG")

# Backup sub-agent workspaces
if [[ "$INCLUDE_SUBAGENT" == "true" ]]; then
    for ws in "$HOME"/.openclaw/workspace-*/; do
        [[ -d "$ws" ]] || continue
        name="$(basename -- "$ws")"
        if ! [[ "$name" =~ ^workspace-[a-zA-Z0-9_-]+$ ]]; then
            echo "⚠️  Skipping suspicious workspace name: $name"
            continue
        fi
        if [[ "$TRANSPORT" == "ssh" ]]; then
            rsync -a --delete -e "ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
                "${EXCLUDE_ARGS[@]}" -- \
                "${ws}" "$(remote_path "backups/$TIMESTAMP/$name/")"
        else
            rsync -a --delete "${EXCLUDE_ARGS[@]}" -- "${ws}" "${SNAP_DIR}/${name}/"
        fi
        echo "✓ $name (sub-agent)"
        (( backed_up++ )) || true
    done
fi

# Write manifest + compute checksum
if [[ "$TRANSPORT" == "smb" ]]; then
    MANIFEST_PATH="${SNAP_DIR}/manifest.json"
else
    MANIFEST_PATH="/tmp/backup-manifest-$TIMESTAMP.json"
fi

cat > "$MANIFEST_PATH" << MANIFEST
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "snapshot": "$TIMESTAMP",
  "host": "$(hostname)",
  "transport": "$TRANSPORT",
  "backed_up": $backed_up,
  "skipped": $skipped
}
MANIFEST

MANIFEST_CHECKSUM="$(md5sum "$MANIFEST_PATH" | cut -d' ' -f1)"

# Upload manifest for SSH transport
if [[ "$TRANSPORT" == "ssh" ]]; then
    rsync -a -e "ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new"         -- "$MANIFEST_PATH" "$(remote_path "backups/$TIMESTAMP/manifest.json")"
    rm -f -- "$MANIFEST_PATH"
fi

# Prune old daily snapshots (SMB only — SSH pruning would need ssh commands)
if [[ "$TRANSPORT" == "smb" ]]; then
    TRASH_DIR="$BACKUP_DIR/.trash"
    mkdir -p -- "$TRASH_DIR"
    while IFS= read -r old_snap; do
        [[ -z "$old_snap" ]] && continue
        if [[ "$old_snap" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            mv -- "${BACKUP_DIR}/${old_snap}" "${TRASH_DIR}/${old_snap}" 2>/dev/null \
                && echo "Pruned: $old_snap"
        fi
    done < <(ls -1 "$BACKUP_DIR" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r | tail -n +"$((RETENTION + 1))")

    # Prune pre-restore safety snapshots older than preRestoreRetention days
    while IFS= read -r pre_snap; do
        [[ -z "$pre_snap" ]] && continue
        snap_date="$(echo "$pre_snap" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
        if [[ -n "$snap_date" ]]; then
            snap_epoch="$(date -d "$snap_date" +%s 2>/dev/null || echo 0)"
            now_epoch="$(date +%s)"
            age_days="$(( (now_epoch - snap_epoch) / 86400 ))"
            if [[ "$age_days" -gt "$PRE_RESTORE_RETENTION" ]]; then
                mv -- "${BACKUP_DIR}/${pre_snap}" "${TRASH_DIR}/${pre_snap}" 2>/dev/null \
                    && echo "Pruned pre-restore: $pre_snap"
            fi
        fi
    done < <(ls -1 "$BACKUP_DIR" | grep -E '^pre-restore-' 2>/dev/null || true)

    # Clean trash older than 3 days
    find "$TRASH_DIR" -maxdepth 1 -mindepth 1 -mtime +3 -exec rm -rf -- {} + 2>/dev/null || true

    TOTAL_SIZE="$(du -sh -- "$SNAP_DIR" 2>/dev/null | cut -f1)"
    SNAP_COUNT="$(ls -1 "$BACKUP_DIR" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' 2>/dev/null || echo 0)"
else
    TOTAL_SIZE="unknown"
    SNAP_COUNT="unknown"
fi

# Write state file (last success timestamp + manifest checksum)
write_success_state "$TIMESTAMP" "$TOTAL_SIZE" "$MANIFEST_CHECKSUM"

echo ""
echo "✅ Backup complete: $TIMESTAMP ($TOTAL_SIZE)"
echo "   $backed_up paths backed up, $skipped skipped"
echo "   Snapshots: $SNAP_COUNT | Manifest checksum: $MANIFEST_CHECKSUM"

# Optional success notification
if [[ "$NOTIFY_ON_SUCCESS" == "true" ]]; then
    send_telegram "✅ Synology backup complete — $TIMESTAMP ($TOTAL_SIZE, $backed_up paths)"
fi

# Clear error trap — succeeded
trap - EXIT
