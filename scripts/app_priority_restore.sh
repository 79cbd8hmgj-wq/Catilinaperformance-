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
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; --help|-h) usage; exit 0 ;; *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;; esac; shift; done
command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null || true; ts=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE" >/dev/null; }
read_key() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$2" 2>/dev/null; }

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
    case "$PID" in ''|*[!0-9]*) log "Skipped malformed state file $file: invalid PID."; SKIPPED=$((SKIPPED+1)); continue ;; esac
    ATTEMPTED=$((ATTEMPTED+1))
    INFO=$(ps -p "$PID" -o comm= 2>/dev/null || true)
    if [ -z "$INFO" ]; then log "Skipped PID=$PID ($SAVED_COMMAND): process no longer exists; saved state retained for troubleshooting."; SKIPPED=$((SKIPPED+1)); continue; fi
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY RUN: would restore PID=$PID ($SAVED_COMMAND) to nice $ORIGINAL_NICE."; SUCCESS=$((SUCCESS+1)); continue; fi
    log "Restoring PID=$PID ($SAVED_COMMAND) to nice $ORIGINAL_NICE."
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        renice -n "$ORIGINAL_NICE" -p "$PID"
    else
        sudo renice -n "$ORIGINAL_NICE" -p "$PID"
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
