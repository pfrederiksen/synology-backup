#!/bin/bash
# Synology Backup — Shared library
# Source this in all scripts: source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# Config loading + validation (no eval, all vars quoted, explicit patterns)
# ---------------------------------------------------------------------------

load_config() {
    local config="$1"
    if [[ ! -f "$config" ]]; then
        echo "Error: Config not found at $config" >&2
        exit 1
    fi
    if ! jq empty "$config" 2>/dev/null; then
        echo "Error: Config is not valid JSON: $config" >&2
        exit 1
    fi

    # Export CONFIG so validate_config can use it for backupPaths iteration
    CONFIG="$config"

    HOST="$(jq -r '.host' "$config")"
    SHARE="$(jq -r '.share' "$config")"
    MOUNT="$(jq -r '.mountPoint // "/mnt/synology"' "$config")"
    CREDS="$(jq -r '.credentialsFile' "$config" | sed "s|^~|$HOME|")"
    SMB_VER="$(jq -r '.smbVersion // "3.0"' "$config")"
    RETENTION="$(jq -r '.retention // 7' "$config")"
    INCLUDE_SUBAGENT="$(jq -r '.includeSubAgentWorkspaces // true' "$config")"
    TRANSPORT="$(jq -r '.transport // "smb"' "$config")"
    SSH_USER="$(jq -r '.sshUser // ""' "$config")"
    TELEGRAM_TARGET="$(jq -r '.telegramTarget // ""' "$config")"

    validate_config
}

validate_config() {
    # Host: safe hostnames/IPs only
    if [[ -z "$HOST" || "$HOST" == "null" ]]; then
        echo "Error: host is required in config" >&2; exit 1
    fi
    if ! [[ "$HOST" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Error: host contains invalid characters" >&2; exit 1
    fi

    # Share path: alphanumeric, slashes, hyphens, underscores, dots
    if [[ -z "$SHARE" || "$SHARE" == "null" ]]; then
        echo "Error: share is required in config" >&2; exit 1
    fi
    if ! [[ "$SHARE" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
        echo "Error: share contains invalid characters" >&2; exit 1
    fi
    if [[ "$SHARE" == *".."* ]]; then
        echo "Error: share must not contain path traversal (..)" >&2; exit 1
    fi

    # Mount point: absolute path
    if [[ -z "$MOUNT" || "$MOUNT" == "null" ]]; then
        echo "Error: mountPoint is required" >&2; exit 1
    fi
    if ! [[ "$MOUNT" =~ ^/[a-zA-Z0-9/_.-]+$ ]]; then
        echo "Error: mountPoint must be an absolute path with safe characters" >&2; exit 1
    fi
    if [[ "$MOUNT" == *".."* ]]; then
        echo "Error: mountPoint must not contain path traversal (..)" >&2; exit 1
    fi

    # SMB version: digits and dots only
    if ! [[ "$SMB_VER" =~ ^[0-9.]+$ ]]; then
        echo "Error: smbVersion contains invalid characters" >&2; exit 1
    fi

    # Retention: positive integer
    if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
        echo "Error: retention must be a non-negative integer" >&2; exit 1
    fi

    # Boolean
    if [[ "$INCLUDE_SUBAGENT" != "true" && "$INCLUDE_SUBAGENT" != "false" ]]; then
        echo "Error: includeSubAgentWorkspaces must be true or false" >&2; exit 1
    fi

    # Transport: explicit allowlist
    if [[ "$TRANSPORT" != "smb" && "$TRANSPORT" != "ssh" ]]; then
        echo "Error: transport must be 'smb' or 'ssh'" >&2; exit 1
    fi

    # Credentials file (required for SMB)
    if [[ "$TRANSPORT" == "smb" ]]; then
        if [[ -z "$CREDS" || "$CREDS" == "null" || ! -f "$CREDS" ]]; then
            echo "Error: credentialsFile not found: $CREDS" >&2; exit 1
        fi
    fi

    # SSH user (required for SSH transport)
    if [[ "$TRANSPORT" == "ssh" ]]; then
        if [[ -z "$SSH_USER" || "$SSH_USER" == "null" ]]; then
            echo "Error: sshUser is required for ssh transport" >&2; exit 1
        fi
        if ! [[ "$SSH_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "Error: sshUser contains invalid characters" >&2; exit 1
        fi
    fi

    # Validate all backup paths
    while IFS= read -r path_raw; do
        validate_path "$path_raw"
    done < <(jq -r '.backupPaths[]' "$CONFIG")
}

validate_path() {
    local p="$1"
    if [[ -z "$p" ]]; then return; fi
    # Reject command substitution, semicolons, pipes, backticks, path traversal
    if [[ "$p" == *'$('* || "$p" == *'`'* || "$p" == *';'* || \
          "$p" == *'|'* || "$p" == *'&'* || "$p" == *".."* ]]; then
        echo "Error: backupPath contains unsafe characters: $p" >&2
        exit 1
    fi
    # Must start with ~ or / 
    if ! [[ "$p" =~ ^[~/] ]]; then
        echo "Error: backupPath must be absolute or home-relative (~): $p" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Mount helpers
# ---------------------------------------------------------------------------

ensure_mounted() {
    if mountpoint -q "$MOUNT" 2>/dev/null; then
        return 0
    fi
    mkdir -p -- "$MOUNT"
    if [[ "$TRANSPORT" == "smb" ]]; then
        mount -t cifs "//${HOST}/${SHARE}" "$MOUNT" \
            -o "credentials=${CREDS},vers=${SMB_VER}"
    fi
    # SSH transport doesn't need a local mount — rsync connects directly
    echo "Mounted //${HOST}/${SHARE} → $MOUNT"
}

# ---------------------------------------------------------------------------
# Telegram alert (uses openclaw message tool via CLI)
# ---------------------------------------------------------------------------

send_telegram() {
    local msg="$1"
    [[ -z "$TELEGRAM_TARGET" ]] && return 0
    # Fire-and-forget — never let a notification failure abort a backup
    openclaw message send \
        --channel telegram \
        --target "$TELEGRAM_TARGET" \
        --message "$msg" 2>/dev/null || true
}
