#!/bin/sh
# Apply a conservative, reversible nice-value boost to one selected process.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_ROOT="$REPO_ROOT/.catalina_performance_state"
STATE_DIR="$STATE_ROOT/app_priority"
LOG_FILE="$STATE_DIR/app_priority.log"
TARGET_NICE=-5
ASSUME_YES=0
ALLOW_ROOT_ADMIN=0
PID=

usage() {
    cat <<USAGE
Usage: $0 --pid PID [--yes] [--allow-root-admin]

Applies a conservative priority boost to one selected user process by changing
its nice value toward $TARGET_NICE. Original state is saved under:
  $STATE_DIR

The script never kills, restarts, or broadens changes to process trees.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pid) shift; [ "$#" -gt 0 ] || { printf 'Missing value for --pid\n' >&2; exit 2; }; PID=$1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --allow-root-admin) ALLOW_ROOT_ADMIN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) if [ -z "$PID" ]; then PID=$1; else printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2; fi ;;
    esac
    shift
done

command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { message=$1; mkdir -p "$STATE_DIR" 2>/dev/null || true; timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null || true; printf '%s\n' "$message"; }
fail() { log "FAILED: $1"; exit 1; }

case "$PID" in ''|*[!0-9]*) printf 'Target PID must be numeric.\n' >&2; exit 2 ;; esac
[ "$PID" != 0 ] && [ "$PID" != 1 ] || fail "Refusing to target PID $PID."
command_exists ps || fail "ps is not available."
command_exists renice || fail "renice is not available."

INFO=$(ps -p "$PID" -o pid=,user=,ni=,comm= 2>/dev/null || true)
[ -n "$INFO" ] || fail "Process $PID does not exist."
OWNER=$(printf '%s\n' "$INFO" | awk '{print $2}')
ORIGINAL_NICE=$(printf '%s\n' "$INFO" | awk '{print $3}')
COMMAND_NAME=$(printf '%s\n' "$INFO" | awk '{for(i=4;i<=NF;i++){printf (i==4?"":" ") $i}}')
CURRENT_USER=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")

case "$COMMAND_NAME" in
    launchd|kernel_task|WindowServer|loginwindow|mds|mds_stores|backupd|syslogd|securityd|coreaudiod|configd|bluetoothd|opendirectoryd|*/launchd|*/kernel_task|*/WindowServer|*/loginwindow|*/mds|*/mds_stores|*/backupd|*/syslogd|*/securityd|*/coreaudiod|*/configd|*/bluetoothd|*/opendirectoryd)
        fail "Refusing to target protected system service: $COMMAND_NAME."
        ;;
esac

if [ "$OWNER" != "$CURRENT_USER" ] && [ "$ALLOW_ROOT_ADMIN" -ne 1 ]; then
    fail "Refusing to target process owned by $OWNER as $CURRENT_USER. Use --allow-root-admin only after reviewing the target."
fi

mkdir -p "$STATE_DIR" || exit 1
chmod 700 "$STATE_ROOT" "$STATE_DIR" 2>/dev/null || true
STATE_FILE="$STATE_DIR/$PID.state"
if [ ! -f "$STATE_FILE" ]; then
    {
        printf 'pid=%s\n' "$PID"
        printf 'owner=%s\n' "$OWNER"
        printf 'command=%s\n' "$COMMAND_NAME"
        printf 'original_nice=%s\n' "$ORIGINAL_NICE"
        printf 'changed_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown)"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
fi

cat <<WARNING
CatalinaPerformance will adjust one selected process only:
  PID: $PID
  Owner: $OWNER
  Command: $COMMAND_NAME
  Current nice: $ORIGINAL_NICE
  Target nice: $TARGET_NICE

This is reversible while the process remains running. No process will be killed,
restarted, or expanded to a process tree.
WARNING

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Continue? Type "BOOST" to proceed: '
    read answer
    [ "$answer" = "BOOST" ] || fail "Aborted by user; no priority change applied."
else
    log "Continuing because --yes was provided."
fi

log "Applying priority boost to PID $PID ($COMMAND_NAME); original nice $ORIGINAL_NICE; target nice $TARGET_NICE."
if renice "$TARGET_NICE" -p "$PID" >/tmp/catalina_priority_renice.$$ 2>&1; then
    cat /tmp/catalina_priority_renice.$$ 2>/dev/null || true
    rm -f /tmp/catalina_priority_renice.$$
    NEW_NICE=$(ps -p "$PID" -o ni= 2>/dev/null | awk '{print $1}')
    log "Priority boost complete for PID $PID; nice is now ${NEW_NICE:-unknown}."
    exit 0
fi
cat /tmp/catalina_priority_renice.$$ 2>/dev/null || true
rm -f /tmp/catalina_priority_renice.$$
if [ "$(id -u 2>/dev/null || printf 1)" != "0" ]; then
    printf 'Administrator authorization may be required to lower a nice value. Re-run through the GUI authorization prompt or sudo.\n'
fi
fail "renice failed for PID $PID. Saved state remains for troubleshooting."
