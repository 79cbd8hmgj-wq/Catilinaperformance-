#!/bin/sh
# Apply a conservative, reversible priority boost to one selected user process.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state/app_priority"
LOG_FILE="$STATE_DIR/app_priority.log"
TARGET_NICE=-5
ASSUME_YES=0
ALLOW_ROOT_ADMIN=0
PID=""

usage() { cat <<USAGE
Usage: $0 --pid PID [--nice -5] [--yes] [--allow-root-admin]

Applies a conservative priority boost to one selected process. The original
nice value is saved under .catalina_performance_state/app_priority/ so it can be
restored later. This script never kills or restarts processes.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pid) shift; PID=${1:-} ;;
        --nice) shift; TARGET_NICE=${1:-} ;;
        --yes|-y) ASSUME_YES=1 ;;
        --allow-root-admin) ALLOW_ROOT_ADMIN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) if [ -z "$PID" ]; then PID=$1; else printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2; fi ;;
    esac
    shift || true
done

command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null || true; ts=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE" >/dev/null; }

case "$PID" in ''|*[!0-9]*) printf 'Refusing to continue: PID must be numeric.\n' >&2; exit 2 ;; esac
[ "$PID" -ne 0 ] 2>/dev/null || { printf 'Refusing to target PID 0.\n' >&2; exit 2; }
[ "$PID" -ne 1 ] 2>/dev/null || { printf 'Refusing to target PID 1 / launchd.\n' >&2; exit 2; }
case "$TARGET_NICE" in -[0-9]|-[0-9][0-9]|[0-9]|[0-9][0-9]) ;; *) printf 'Refusing to continue: --nice must be a small integer value.\n' >&2; exit 2 ;; esac
if [ "$TARGET_NICE" -lt -10 ] || [ "$TARGET_NICE" -gt 20 ]; then printf 'Refusing nice value outside safe range -10..20.\n' >&2; exit 2; fi

command_exists ps || { printf 'ps is required.\n' >&2; exit 1; }
command_exists renice || { printf 'renice is required to change process priority.\n' >&2; exit 1; }

INFO=$(ps -p "$PID" -o user=,nice=,comm= 2>/dev/null || true)
[ -n "$INFO" ] || { printf 'Refusing to continue: process %s does not exist.\n' "$PID" >&2; exit 1; }
OWNER=$(printf '%s\n' "$INFO" | awk '{print $1; exit}')
ORIGINAL_NICE=$(printf '%s\n' "$INFO" | awk '{print $2; exit}')
COMMAND_NAME=$(printf '%s\n' "$INFO" | awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit}')
CURRENT_USER=$(id -un 2>/dev/null || printf '')

case "$COMMAND_NAME" in
    kernel_task|launchd|WindowServer|loginwindow|mds|mds_stores|backupd|syslogd|securityd|coreaudiod|configd|bluetoothd|opendirectoryd|*/kernel_task|*/launchd|*/WindowServer|*/loginwindow|*/mds|*/mds_stores|*/backupd|*/syslogd|*/securityd|*/coreaudiod|*/configd|*/bluetoothd|*/opendirectoryd)
        printf 'Refusing to target protected system process: %s\n' "$COMMAND_NAME" >&2; exit 2 ;;
esac

if [ "$ALLOW_ROOT_ADMIN" -ne 1 ] && [ -n "$CURRENT_USER" ] && [ "$OWNER" != "$CURRENT_USER" ]; then
    printf 'Refusing to target PID %s owned by %s. Current user is %s. Use --allow-root-admin only after review.\n' "$PID" "$OWNER" "$CURRENT_USER" >&2
    exit 2
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Apply conservative priority boost to PID %s (%s), owner %s, nice %s -> %s? [y/N] ' "$PID" "$COMMAND_NAME" "$OWNER" "$ORIGINAL_NICE" "$TARGET_NICE"
    read answer || answer=no
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled by user.\n'; exit 1 ;; esac
fi

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$PID.state"
if [ ! -f "$STATE_FILE" ]; then
    {
        printf 'PID=%s\n' "$PID"
        printf 'OWNER=%s\n' "$OWNER"
        printf 'COMMAND=%s\n' "$COMMAND_NAME"
        printf 'ORIGINAL_NICE=%s\n' "$ORIGINAL_NICE"
        printf 'TARGET_NICE=%s\n' "$TARGET_NICE"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time)"
    } > "$STATE_FILE"
fi

log "Applying app priority boost: PID=$PID command=$COMMAND_NAME owner=$OWNER nice=$ORIGINAL_NICE -> $TARGET_NICE"
if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
    if ! renice -n "$TARGET_NICE" -p "$PID"; then
        log "FAILED to apply app priority boost to PID=$PID."
        printf 'Failed to apply priority boost to PID %s. Saved state remains for troubleshooting.\n' "$PID" >&2
        exit 1
    fi
else
    printf 'Administrator authorization may be required to set a negative nice value.\n'
    if ! sudo renice -n "$TARGET_NICE" -p "$PID"; then
        log "FAILED to apply app priority boost to PID=$PID."
        printf 'Failed to apply priority boost to PID %s. Saved state remains for troubleshooting.\n' "$PID" >&2
        exit 1
    fi
fi
log "Applied app priority boost to PID=$PID. Restore with scripts/app_priority_restore.sh --yes."
printf 'Priority boost applied to PID %s (%s). Original nice value %s saved in %s.\n' "$PID" "$COMMAND_NAME" "$ORIGINAL_NICE" "$STATE_FILE"
