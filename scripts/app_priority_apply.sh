#!/bin/sh
# Apply a conservative, reversible priority boost to one selected user process.

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
ARCHIVE_DIR="$STATE_DIR/archive"
LOG_FILE="$STATE_DIR/app_priority.log"
TARGET_NICE=-5
ASSUME_YES=0
ALLOW_ROOT_ADMIN=0
EXPECTED_OWNER=""
EXPECTED_COMMAND=""
EXPECTED_START=""
EXPECTED_FULL_COMMAND=""
PID=""

usage() { cat <<USAGE
Usage: $0 --pid PID [--nice -5] [--yes] [--expected-owner USER] [--expected-command COMMAND] [--expected-start START] [--expected-full-command COMMANDLINE]

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
        --expected-command) shift; EXPECTED_COMMAND=${1:-} ;;
        --expected-start) shift; EXPECTED_START=${1:-} ;;
        --expected-full-command) shift; EXPECTED_FULL_COMMAND=${1:-} ;;
        --allow-root-admin) ALLOW_ROOT_ADMIN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) if [ -z "$PID" ]; then PID=$1; else printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2; fi ;;
    esac
    shift || true
done

command_exists() { command -v "$1" >/dev/null 2>&1; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null || true; ts=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown-time); printf '%s %s\n' "$ts" "$1" | tee -a "$LOG_FILE" >/dev/null; }
read_key() { awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1); exit}' "$2" 2>/dev/null; }
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

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

if [ -n "$EXPECTED_OWNER" ] || [ -n "$EXPECTED_COMMAND" ] || [ -n "$EXPECTED_START" ] || [ -n "$EXPECTED_FULL_COMMAND" ]; then
    if [ -z "$EXPECTED_OWNER" ] || [ -z "$EXPECTED_COMMAND" ]; then
        printf 'Aborted: selected process identity changed; refresh the process list and try again.\n' >&2
        printf 'Expected owner and command are required for App Priority identity verification.\n' >&2
        exit 1
    fi
    if [ -z "$EXPECTED_START" ] && [ -z "$EXPECTED_FULL_COMMAND" ]; then
        printf 'Aborted: selected process identity changed; refresh the process list and try again.\n' >&2
        printf 'Expected process start time or full command is required; refusing PID-only verification.\n' >&2
        exit 1
    fi
    if [ "$OWNER" != "$EXPECTED_OWNER" ] || [ "$COMMAND_NAME" != "$EXPECTED_COMMAND" ]; then
        printf 'Aborted: selected process identity changed; refresh the process list and try again.\n' >&2
        exit 1
    fi
    if [ -n "$EXPECTED_START" ]; then
        if [ -z "$START_TIME" ] || [ "$START_TIME" != "$EXPECTED_START" ]; then
            printf 'Aborted: selected process identity changed; refresh the process list and try again.\n' >&2
            exit 1
        fi
    elif [ -n "$EXPECTED_FULL_COMMAND" ]; then
        if [ -z "$FULL_COMMAND" ] || [ "$FULL_COMMAND" != "$EXPECTED_FULL_COMMAND" ]; then
            printf 'Aborted: selected process identity changed; refresh the process list and try again.\n' >&2
            exit 1
        fi
    fi
fi

identity_still_matches_current() {
    check_info=$(ps -p "$PID" -o user=,comm= 2>/dev/null || true)
    [ -n "$check_info" ] || return 1
    check_owner=$(printf '%s\n' "$check_info" | awk '{print $1; exit}')
    check_command=$(printf '%s\n' "$check_info" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print; exit}')
    check_start=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -n '1p' || printf '')
    check_full=$(ps -p "$PID" -o args= 2>/dev/null | sed -n '1p' || printf '')

    [ "$check_owner" = "$OWNER" ] || return 1
    [ "$check_command" = "$COMMAND_NAME" ] || return 1
    if [ -n "$START_TIME" ]; then
        [ "$check_start" = "$START_TIME" ] || return 1
    elif [ -n "$FULL_COMMAND" ]; then
        [ "$check_full" = "$FULL_COMMAND" ] || return 1
    else
        return 1
    fi
    return 0
}

state_matches_current() {
    file=$1
    [ "$(read_key PID "$file")" = "$PID" ] || return 1
    [ "$(read_key OWNER "$file")" = "$OWNER" ] || return 1
    [ "$(read_key COMMAND "$file")" = "$COMMAND_NAME" ] || return 1
    saved_start=$(read_key START_TIME "$file")
    saved_full=$(read_key FULL_COMMAND "$file")
    [ -n "$saved_start" ] || return 1
    [ -n "$START_TIME" ] || return 1
    if [ "$saved_start" != "$START_TIME" ]; then return 1; fi
    if [ -n "$saved_full" ] && [ -n "$FULL_COMMAND" ] && [ "$saved_full" != "$FULL_COMMAND" ]; then return 1; fi
    return 0
}

write_state() {
    status=$1
    tmp_file="$STATE_FILE.tmp.$$"
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
    } > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
}

abort_without_state() {
    printf 'Aborted: could not save restore state before applying priority boost.\n' >&2
    printf 'No priority change was attempted. Check permissions for: %s\n' "$STATE_DIR" >&2
    exit 1
}

verify_state_saved() {
    if [ ! -f "$STATE_FILE" ] || [ ! -r "$STATE_FILE" ]; then
        return 1
    fi
    [ "$(read_key PID "$STATE_FILE")" = "$PID" ] || return 1
    [ "$(read_key OWNER "$STATE_FILE")" = "$OWNER" ] || return 1
    [ "$(read_key COMMAND "$STATE_FILE")" = "$COMMAND_NAME" ] || return 1
    [ -n "$(read_key ORIGINAL_NICE "$STATE_FILE")" ] || return 1
    [ -n "$(read_key APPLY_STATUS "$STATE_FILE")" ] || return 1
    return 0
}

mark_state_status() {
    status=$1
    if [ -f "$STATE_FILE" ] && state_matches_current "$STATE_FILE"; then
        tmp_file="$STATE_FILE.tmp.$$"
        awk -v status="$status" 'BEGIN{done=0} /^APPLY_STATUS=/ {print "APPLY_STATUS=" status; done=1; next} {print} END{if(!done) print "APPLY_STATUS=" status}' "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
}

mkdir -p "$STATE_DIR" || abort_without_state
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
        write_state pending || abort_without_state
    fi
else
    write_state pending || abort_without_state
fi
verify_state_saved || abort_without_state

if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Apply conservative priority boost to PID %s (%s), owner %s, nice %s -> %s? [y/N] ' "$PID" "$COMMAND_NAME" "$OWNER" "$ORIGINAL_NICE" "$TARGET_NICE"
    read answer || answer=no
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            mark_state_status cancelled
            log "Cancelled app priority boost before renice for PID=$PID. No successful boost was applied."
            printf 'Cancelled by user.\n'
            exit 1
            ;;
    esac
fi

run_renice() {
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        if ! identity_still_matches_current; then
            printf 'Aborted: selected process identity changed before priority boost.\n' >&2
            return 1
        fi
        printf 'Running: renice %s -p %s\n' "$TARGET_NICE" "$PID"
        renice "$TARGET_NICE" -p "$PID"
        return $?
    fi
    if [ "$TARGET_NICE" -ge 0 ]; then
        if ! identity_still_matches_current; then
            printf 'Aborted: selected process identity changed before priority boost.\n' >&2
            return 1
        fi
        printf 'Running: renice %s -p %s\n' "$TARGET_NICE" "$PID"
        renice "$TARGET_NICE" -p "$PID"
        return $?
    fi
    if command_exists osascript; then
        printf 'Administrator authorization may be required only for the renice command.\n'
        check_script="$STATE_DIR/renice_identity_check_$PID_$$.sh"
        {
            printf '#!/bin/sh\n'
            printf 'PID=%s\n' "$(shell_quote "$PID")"
            printf 'OWNER=%s\n' "$(shell_quote "$OWNER")"
            printf 'COMMAND_NAME=%s\n' "$(shell_quote "$COMMAND_NAME")"
            printf 'START_TIME=%s\n' "$(shell_quote "$START_TIME")"
            printf 'FULL_COMMAND=%s\n' "$(shell_quote "$FULL_COMMAND")"
            printf 'TARGET_NICE=%s\n' "$(shell_quote "$TARGET_NICE")"
            cat <<'CHECKSCRIPT'
info=$(ps -p "$PID" -o user=,comm= 2>/dev/null || true)
current_owner=$(printf '%s\n' "$info" | awk '{print $1; exit}')
current_command=$(printf '%s\n' "$info" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print; exit}')
current_start=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -n '1p' || printf '')
current_full=$(ps -p "$PID" -o args= 2>/dev/null | sed -n '1p' || printf '')
if [ -z "$info" ] || [ "$current_owner" != "$OWNER" ] || [ "$current_command" != "$COMMAND_NAME" ]; then
    printf 'Aborted: selected process identity changed before priority boost.\n' >&2
    exit 44
fi
if [ -n "$START_TIME" ]; then
    if [ "$current_start" != "$START_TIME" ]; then
        printf 'Aborted: selected process identity changed before priority boost.\n' >&2
        exit 44
    fi
elif [ -n "$FULL_COMMAND" ]; then
    if [ "$current_full" != "$FULL_COMMAND" ]; then
        printf 'Aborted: selected process identity changed before priority boost.\n' >&2
        exit 44
    fi
else
    printf 'Aborted: selected process identity changed before priority boost.\n' >&2
    exit 44
fi
/usr/bin/renice "$TARGET_NICE" -p "$PID"
CHECKSCRIPT
        } > "$check_script" || return 1
        chmod 700 "$check_script" 2>/dev/null || true
        quoted_script=$(shell_quote "$check_script")
        osascript -e "do shell script \"/bin/sh $quoted_script\" with administrator privileges"
        result=$?
        rm -f "$check_script" 2>/dev/null || true
        return $result
    fi
    printf 'Administrator authorization is required to set a negative nice value. Command: renice %s -p %s\n' "$TARGET_NICE" "$PID"
    if ! identity_still_matches_current; then
        printf 'Aborted: selected process identity changed before priority boost.\n' >&2
        return 1
    fi
    if command_exists sudo; then sudo renice "$TARGET_NICE" -p "$PID"; else return 1; fi
}

log "Applying app priority boost: PID=$PID command=$COMMAND_NAME owner=$OWNER start_time=$START_TIME nice=$ORIGINAL_NICE -> $TARGET_NICE"
if ! run_renice; then
    mark_state_status failed
    log "FAILED to apply app priority boost to PID=$PID. No successful boost was applied; diagnostic state is preserved for troubleshooting."
    printf 'Failed to apply priority boost to PID %s. No successful boost was applied; saved state remains for troubleshooting and will be skipped by restore.\n' "$PID" >&2
    exit 1
fi

mark_state_status applied
log "Applied app priority boost to PID=$PID. Restore with scripts/app_priority_restore.sh --yes."
printf 'Priority boost applied to PID %s (%s). Original nice value is saved in %s.\n' "$PID" "$COMMAND_NAME" "$STATE_FILE"
