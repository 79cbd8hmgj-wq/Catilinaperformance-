#!/bin/sh
# Restore nice values saved by app_priority_apply.sh.

set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state/app_priority"
LOG_FILE="$STATE_DIR/app_priority.log"
DRY_RUN=0
ASSUME_YES=0
ATTEMPTED=0
SUCCESS=0
SKIPPED=0
FAILED=0

usage() { printf 'Usage: %s [--dry-run] [--yes]\n' "$0"; }
while [ "$#" -gt 0 ]; do
    case "$1" in --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --help|-h) usage; exit 0 ;; *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;; esac
    shift
done
command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { message=$1; timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); [ -d "$STATE_DIR" ] && printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null || true; printf '%s\n' "$message"; }

if [ ! -d "$STATE_DIR" ]; then
    printf 'No App Priority saved state exists at %s. Nothing to restore.\n' "$STATE_DIR"
    exit 0
fi
command_exists ps || { printf 'ps is not available; cannot restore process priorities.\n' >&2; exit 1; }
command_exists renice || { printf 'renice is not available; cannot restore process priorities.\n' >&2; exit 1; }

if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    printf 'Restore saved App Priority nice values? Type "RESTORE" to proceed: '
    read answer
    [ "$answer" = "RESTORE" ] || { printf 'Aborted by user; no priority restore applied.\n'; exit 1; }
fi

for state_file in "$STATE_DIR"/*.state; do
    [ -e "$state_file" ] || continue
    PID=$(awk -F= '$1=="pid" {print $2}' "$state_file" | tail -1)
    ORIGINAL_NICE=$(awk -F= '$1=="original_nice" {print $2}' "$state_file" | tail -1)
    COMMAND_NAME=$(awk -F= '$1=="command" {print substr($0, index($0,"=")+1)}' "$state_file" | tail -1)
    ATTEMPTED=$((ATTEMPTED + 1))
    case "$PID:$ORIGINAL_NICE" in *[!0-9:-]*|:*) log "Skipped invalid state file: $state_file"; SKIPPED=$((SKIPPED + 1)); continue ;; esac
    if ! ps -p "$PID" >/dev/null 2>&1; then
        log "Skipped PID $PID ($COMMAND_NAME): process no longer exists."
        SKIPPED=$((SKIPPED + 1)); continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would restore PID $PID ($COMMAND_NAME) to nice $ORIGINAL_NICE."
        continue
    fi
    log "Restoring PID $PID ($COMMAND_NAME) to nice $ORIGINAL_NICE."
    if renice "$ORIGINAL_NICE" -p "$PID" >/tmp/catalina_priority_restore.$$ 2>&1; then
        cat /tmp/catalina_priority_restore.$$ 2>/dev/null || true
        SUCCESS=$((SUCCESS + 1))
        printf 'restored_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown)" >> "$state_file" 2>/dev/null || true
    else
        cat /tmp/catalina_priority_restore.$$ 2>/dev/null || true
        log "FAILED: could not restore PID $PID to nice $ORIGINAL_NICE. Administrator authorization may be required."
        FAILED=$((FAILED + 1))
    fi
    rm -f /tmp/catalina_priority_restore.$$
done

printf '\nApp Priority restore summary\n'
printf 'Attempted restores: %s\n' "$ATTEMPTED"
printf 'Successful restores: %s\n' "$SUCCESS"
printf 'Skipped restores: %s\n' "$SKIPPED"
printf 'Failed restores: %s\n' "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
