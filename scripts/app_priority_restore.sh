#!/bin/sh
# Restore nice values saved by app_priority_apply.sh.

set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
default_app_priority_state_dir() {
    if [ -n "${CATALINA_PERFORMANCE_APP_PRIORITY_STATE_DIR:-}" ]; then
        printf '%s' "$CATALINA_PERFORMANCE_APP_PRIORITY_STATE_DIR"
        return 0
    fi
    if [ -n "${CATALINA_PERFORMANCE_USER_HOME:-}" ]; then
        printf '%s/Library/Application Support/CatalinaPerformance/app_priority' "$CATALINA_PERFORMANCE_USER_HOME"
        return 0
    fi
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ] && command -v stat >/dev/null 2>&1; then
        console_user=$(stat -f %Su /dev/console 2>/dev/null || printf '')
        if [ -n "$console_user" ] && [ "$console_user" != "root" ] && [ -d "/Users/$console_user" ]; then
            printf '/Users/%s/Library/Application Support/CatalinaPerformance/app_priority' "$console_user"
            return 0
        fi
    fi
    printf '%s/Library/Application Support/CatalinaPerformance/app_priority' "${HOME:-$REPO_ROOT}"
}

STATE_DIR=$(default_app_priority_state_dir)
LOG_FILE="$STATE_DIR/app_priority.log"
DRY_RUN=0
ASSUME_YES=0
ATTEMPTED=0
SUCCESS=0
SKIPPED=0
FAILED=0

usage() { printf 'Usage: %s [--dry-run] [--yes]\n' "$0"; }
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --help|-h) usage; exit 0 ;; *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;; esac; shift; done
command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null || true; ts=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE"; }
read_key() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$2" 2>/dev/null; }

identity_mismatch() {
    file=$1
    pid=$2

    saved_owner=$(read_key OWNER "$file")
    saved_command=$(read_key COMMAND "$file")
    saved_full_command=$(read_key FULL_COMMAND "$file")
    saved_start_time=$(read_key START_TIME "$file")

    current_info=$(ps -p "$pid" -o user=,comm= 2>/dev/null || true)
    [ -n "$current_info" ] || return 2
    current_owner=$(printf '%s\n' "$current_info" | awk '{print $1; exit}')
    current_command=$(printf '%s\n' "$current_info" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print; exit}')
    current_full_command=$(ps -p "$pid" -o args= 2>/dev/null | sed -n '1p' || printf '')
    current_start_time=$(ps -p "$pid" -o lstart= 2>/dev/null | sed -n '1p' || printf '')

    if [ -z "$saved_owner" ] || [ -z "$saved_command" ] || [ -z "$saved_start_time" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: saved owner, command, or start time is missing."
        return 0
    fi
    if [ -z "$current_owner" ] || [ -z "$current_command" ] || [ -z "$current_start_time" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: current owner, command, or start time could not be read."
        return 0
    fi
    if [ "$saved_owner" != "$current_owner" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: saved owner=$saved_owner current owner=$current_owner."
        return 0
    fi
    if [ "$saved_command" != "$current_command" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: saved command=$saved_command current command=$current_command."
        return 0
    fi
    if [ "$saved_start_time" != "$current_start_time" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: saved start time=$saved_start_time current start time=$current_start_time."
        return 0
    fi
    if [ -n "$saved_full_command" ] && [ -n "$current_full_command" ] && [ "$saved_full_command" != "$current_full_command" ]; then
        log "Skipped stale PID / identity mismatch for PID=$pid: saved full command differs from current full command."
        return 0
    fi

    return 1
}

if [ ! -d "$STATE_DIR" ]; then printf 'No app-priority state directory found; nothing to restore.\n'; exit 0; fi
set -- "$STATE_DIR"/*.state
if [ ! -e "$1" ]; then printf 'No saved app-priority process state found; nothing to restore.\n'; exit 0; fi
command_exists ps || { printf 'ps is required.\n' >&2; exit 1; }
command_exists renice || { printf 'renice is required.\n' >&2; exit 1; }

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    printf 'Restore saved app-priority nice values for CatalinaPerformance-managed processes? [y/N] '
    read answer || answer=no
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled by user.\n'; exit 1 ;; esac
fi

for file in "$STATE_DIR"/*.state; do
    [ -f "$file" ] || continue
    PID=$(read_key PID "$file")
    ORIGINAL_NICE=$(read_key ORIGINAL_NICE "$file")
    SAVED_COMMAND=$(read_key COMMAND "$file")
    APPLY_STATUS=$(read_key APPLY_STATUS "$file")
    case "$PID" in ''|*[!0-9]*) log "Skipped malformed state file $file: invalid PID."; SKIPPED=$((SKIPPED+1)); continue ;; esac
    case "$ORIGINAL_NICE" in -[0-9]|-[0-9][0-9]|[0-9]|[0-9][0-9]) ;; *) log "Skipped PID=$PID ($SAVED_COMMAND): saved original nice value is invalid."; SKIPPED=$((SKIPPED+1)); continue ;; esac
    ATTEMPTED=$((ATTEMPTED+1))
    case "$APPLY_STATUS" in
        applied) ;;
        pending|failed|cancelled)
            log "Skipped PID=$PID ($SAVED_COMMAND): APPLY_STATUS=$APPLY_STATUS means no confirmed successful boost should be restored; state preserved for troubleshooting."
            SKIPPED=$((SKIPPED+1))
            continue
            ;;
        ''|*)
            log "Skipped PID=$PID ($SAVED_COMMAND): missing or malformed APPLY_STATUS; only APPLY_STATUS=applied is restored."
            SKIPPED=$((SKIPPED+1))
            continue
            ;;
    esac
    INFO=$(ps -p "$PID" -o comm= 2>/dev/null || true)
    if [ -z "$INFO" ]; then log "Skipped PID=$PID ($SAVED_COMMAND): process no longer exists; saved state retained for troubleshooting."; SKIPPED=$((SKIPPED+1)); continue; fi
    identity_mismatch "$file" "$PID"
    identity_status=$?
    if [ "$identity_status" -eq 0 ]; then SKIPPED=$((SKIPPED+1)); continue; fi
    if [ "$identity_status" -eq 2 ]; then log "Skipped PID=$PID ($SAVED_COMMAND): process no longer exists during identity verification."; SKIPPED=$((SKIPPED+1)); continue; fi
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY RUN: identity matches; would run absolute restore: renice $ORIGINAL_NICE -p $PID."; SUCCESS=$((SUCCESS+1)); continue; fi
    log "Restoring PID=$PID ($SAVED_COMMAND) with absolute nice command: renice $ORIGINAL_NICE -p $PID."
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        renice "$ORIGINAL_NICE" -p "$PID"
    else
        sudo renice "$ORIGINAL_NICE" -p "$PID"
    fi
    if [ "$?" -eq 0 ]; then
        SUCCESS=$((SUCCESS+1))
        mv "$file" "$file.restored.$(date +%Y%m%d%H%M%S 2>/dev/null || printf time)" 2>/dev/null || true
        log "Restored PID=$PID successfully."
    else
        FAILED=$((FAILED+1)); log "FAILED to restore PID=$PID."
    fi
done

printf '\nApp Priority restore summary\n'
printf 'Attempted restores: %s\nSuccessful restores: %s\nSkipped restores: %s\nFailed restores: %s\n' "$ATTEMPTED" "$SUCCESS" "$SKIPPED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
