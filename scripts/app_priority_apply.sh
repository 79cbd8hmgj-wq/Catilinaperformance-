#!/bin/sh
# Apply a conservative, reversible priority boost to one selected user process.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state/app_priority"
ARCHIVE_DIR="$STATE_DIR/archive"
LOG_FILE="$STATE_DIR/app_priority.log"
TARGET_NICE=-5
ASSUME_YES=0
ALLOW_ROOT_ADMIN=0
EXPECTED_OWNER=""
PID=""

usage() { cat <<USAGE
Usage: $0 --pid PID [--nice -5] [--yes] [--expected-owner USER]

Applies a conservative priority boost to one selected user-owned process. The
original nice value and process identity are saved before renice runs so restore
can verify it is touching the same process. This script never kills or restarts
processes.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pid) shift; PID=${1:-} ;;
        --nice) shift; TARGET_NICE=${1:-} ;;
        --yes|-y) ASSUME_YES=1 ;;
        --expected-owner) shift; EXPECTED_OWNER=${1:-} ;;
        --allow-root-admin) ALLOW_ROOT_ADMIN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) if [ -z "$PID" ]; then PID=$1; else printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2; fi ;;
    esac
    shift || true
done

command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null || true; ts=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE" >/dev/null; }
read_key() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$2" 2>/dev/null; }

case "$PID" in ''|*[!0-9]*) printf 'Refusing to continue: PID must be numeric.\n' >&2; exit 2 ;; esac
[ "$PID" -ne 0 ] 2>/dev/null || { printf 'Refusing to target PID 0.\n' >&2; exit 2; }
[ "$PID" -ne 1 ] 2>/dev/null || { printf 'Refusing to target PID 1 / launchd.\n' >&2; exit 2; }
case "$TARGET_NICE" in -[0-9]|-[0-9][0-9]|[0-9]|[0-9][0-9]) ;; *) printf 'Refusing to continue: --nice must be a small integer value.\n' >&2; exit 2 ;; esac
if [ "$TARGET_NICE" -lt -10 ] || [ "$TARGET_NICE" -gt 20 ]; then printf 'Refusing nice value outside safe range -10..20.\n' >&2; exit 2; fi
case "$EXPECTED_OWNER" in *[!A-Za-z0-9._-]*) [ -z "$EXPECTED_OWNER" ] || { printf 'Refusing invalid expected owner: %s\n' "$EXPECTED_OWNER" >&2; exit 2; } ;; esac

command_exists ps || { printf 'ps is required.\n' >&2; exit 1; }
command_exists renice || { printf 'renice is required to change process priority.\n' >&2; exit 1; }

INFO=$(ps -p "$PID" -o user=,nice=,comm= 2>/dev/null || true)
[ -n "$INFO" ] || { printf 'Refusing to continue: process %s does not exist.\n' "$PID" >&2; exit 1; }
OWNER=$(printf '%s\n' "$INFO" | awk '{print $1; exit}')
ORIGINAL_NICE=$(printf '%s\n' "$INFO" | awk '{print $2; exit}')
COMMAND_NAME=$(printf '%s\n' "$INFO" | awk '{$1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit}')
FULL_COMMAND=$(ps -p "$PID" -o args= 2>/dev/null | sed -n '1p' || printf '')
START_TIME=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -n '1p' || printf '')
CURRENT_USER=$(id -un 2>/dev/null || printf '')
VALIDATION_USER=$CURRENT_USER
[ -n "$EXPECTED_OWNER" ] && VALIDATION_USER=$EXPECTED_OWNER

case "$COMMAND_NAME" in
    kernel_task|launchd|WindowServer|loginwindow|mds|mds_stores|backupd|syslogd|securityd|coreaudiod|configd|bluetoothd|opendirectoryd|*/kernel_task|*/launchd|*/WindowServer|*/loginwindow|*/mds|*/mds_stores|*/backupd|*/syslogd|*/securityd|*/coreaudiod|*/configd|*/bluetoothd|*/opendirectoryd)
        printf 'Refusing to target protected system process: %s\n' "$COMMAND_NAME" >&2; exit 2 ;;
esac

if [ "$ALLOW_ROOT_ADMIN" -ne 1 ] && [ -n "$VALIDATION_USER" ] && [ "$OWNER" != "$VALIDATION_USER" ]; then
    printf 'Refusing to target PID %s owned by %s. Expected owner is %s.\n' "$PID" "$OWNER" "$VALIDATION_USER" >&2
    exit 2
fi
if [ "$ALLOW_ROOT_ADMIN" -ne 1 ] && [ "$OWNER" = "root" ]; then
    printf 'Refusing to target root-owned process without an explicit future experimental flag.\n' >&2
    exit 2
fi

state_matches_current() {
    file=$1
    [ "$(read_key PID "$file")" = "$PID" ] || return 1
    [ "$(read_key OWNER "$file")" = "$OWNER" ] || return 1
    [ "$(read_key COMMAND "$file")" = "$COMMAND_NAME" ] || return 1
    saved_start=$(read_key START_TIME "$file")
    saved_full=$(read_key FULL_COMMAND "$file")
    if [ -n "$saved_start" ] && [ -n "$START_TIME" ] && [ "$saved_start" != "$START_TIME" ]; then return 1; fi
    if [ -n "$saved_full" ] && [ -n "$FULL_COMMAND" ] && [ "$saved_full" != "$FULL_COMMAND" ]; then return 1; fi
    return 0
}

write_state() {
    status=$1
    {
        printf 'PID=%s\n' "$PID"
        printf 'OWNER=%s\n' "$OWNER"
        printf 'COMMAND=%s\n' "$COMMAND_NAME"
        printf 'FULL_COMMAND=%s\n' "$FULL_COMMAND"
        printf 'START_TIME=%s\n' "$START_TIME"
        printf 'ORIGINAL_NICE=%s\n' "$ORIGINAL_NICE"
        printf 'TARGET_NICE=%s\n' "$TARGET_NICE"
        printf 'APPLY_STATUS=%s\n' "$status"
        printf 'APPLIED_AT=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time)"
    } > "$STATE_FILE"
}

mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/$PID.state"
if [ -f "$STATE_FILE" ]; then
    if state_matches_current "$STATE_FILE"; then
        saved_status=$(read_key APPLY_STATUS "$STATE_FILE")
        log "Existing valid app-priority state found for PID=$PID command=$COMMAND_NAME status=${saved_status:-unknown}; preserving original nice value for restore."
    else
        mkdir -p "$ARCHIVE_DIR"
        archive_file="$ARCHIVE_DIR/$PID.stale.$(date +%Y%m%d%H%M%S 2>/dev/null || printf time).state"
        mv "$STATE_FILE" "$archive_file" || { printf 'Refusing to continue: unable to archive stale state file %s.\n' "$STATE_FILE" >&2; exit 1; }
        log "Archived stale app-priority state for reused PID=$PID to $archive_file before applying a new boost."
        write_state pending
    fi
else
    write_state pending
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Apply conservative priority boost to PID %s (%s), owner %s, nice %s -> %s? [y/N] ' "$PID" "$COMMAND_NAME" "$OWNER" "$ORIGINAL_NICE" "$TARGET_NICE"
    read answer || answer=no
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled by user.\n'; exit 1 ;; esac
fi

run_renice() {
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        printf 'Running: renice %s -p %s\n' "$TARGET_NICE" "$PID"
        renice "$TARGET_NICE" -p "$PID"
        return $?
    fi
    if [ "$TARGET_NICE" -ge 0 ]; then
        printf 'Running: renice %s -p %s\n' "$TARGET_NICE" "$PID"
        renice "$TARGET_NICE" -p "$PID"
        return $?
    fi
    if command_exists osascript; then
        printf 'Administrator authorization may be required only for the renice command.\n'
        command_text="/usr/bin/renice $TARGET_NICE -p $PID"
        osascript -e "do shell script \"$command_text\" with administrator privileges"
        return $?
    fi
    printf 'Administrator authorization is required to set a negative nice value. Command: renice %s -p %s\n' "$TARGET_NICE" "$PID"
    if command_exists sudo; then sudo renice "$TARGET_NICE" -p "$PID"; else return 1; fi
}

log "Applying app priority boost: PID=$PID command=$COMMAND_NAME owner=$OWNER start_time=$START_TIME nice=$ORIGINAL_NICE -> $TARGET_NICE"
if ! run_renice; then
    if [ -f "$STATE_FILE" ] && state_matches_current "$STATE_FILE"; then
        tmp_file="$STATE_FILE.tmp.$$"
        awk 'BEGIN{done=0} /^APPLY_STATUS=/ {print "APPLY_STATUS=failed"; done=1; next} {print} END{if(!done) print "APPLY_STATUS=failed"}' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
    log "FAILED to apply app priority boost to PID=$PID. State is preserved for troubleshooting."
    printf 'Failed to apply priority boost to PID %s. Saved state remains for restore/troubleshooting.\n' "$PID" >&2
    exit 1
fi

if [ -f "$STATE_FILE" ] && state_matches_current "$STATE_FILE"; then
    tmp_file="$STATE_FILE.tmp.$$"
    awk 'BEGIN{done=0} /^APPLY_STATUS=/ {print "APPLY_STATUS=applied"; done=1; next} {print} END{if(!done) print "APPLY_STATUS=applied"}' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
fi
log "Applied app priority boost to PID=$PID. Restore with scripts/app_priority_restore.sh --yes."
printf 'Priority boost applied to PID %s (%s). Original nice value is saved in %s.\n' "$PID" "$COMMAND_NAME" "$STATE_FILE"
