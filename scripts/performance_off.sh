#!/bin/sh
# Turn CatalinaPerformance Performance Mode OFF.
#
# Safety model:
# - Reads saved state from .catalina_performance_state/ created by performance_on.sh.
# - Restores only conservative, reversible settings that performance_on.sh recorded.
# - Keeps state and the ON marker if any restore action fails so the user can retry.
# - Does not modify SIP, delete caches, unload launch daemons, touch fan control,
#   undervolt, load kexts, or use experimental CPU/MSR changes.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state"
LOG_FILE="$STATE_DIR/performance_off.log"
MARKER_FILE="$STATE_DIR/performance_mode_on"
PMSET_RESTORE_FILE="$STATE_DIR/pmset_restore_commands.sh"
TMUTIL_STATE_FILE="$STATE_DIR/timemachine_before.txt"
MDUTIL_STATE_FILE="$STATE_DIR/spotlight_boot_before.txt"
ACTIONS_FILE="$STATE_DIR/actions_taken.txt"
RESTORE_ACTIONS_FILE="$STATE_DIR/restore_actions_taken.txt"
APP_PRIORITY_STATE_DIR="$STATE_DIR/app_priority"
APP_PRIORITY_RESTORE_SCRIPT="$SCRIPT_DIR/app_priority_restore.sh"

FORCE=0
DRY_RUN=0
RESTORE_FAILURES=0
RESTORE_ATTEMPTS=0

usage() {
    cat <<USAGE
Usage: $0 [--force] [--dry-run]

Turns CatalinaPerformance Performance Mode OFF by restoring saved state.

Options:
  --force    Run even if the Performance Mode ON marker is missing.
  --dry-run  Print restore actions without changing settings or removing state.

This script may use sudo only for macOS commands that normally require
administrator privileges: pmset, tmutil enable, and mdutil -i on /.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Command lookup helper used before macOS-specific restore commands.
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Platform detection keeps the script safe to run on non-macOS systems.
is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

# Log every restore action to a state-directory log and to the terminal.
log() {
    message=$1
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'unknown-time')
    if [ -d "$STATE_DIR" ]; then
        printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    printf '%s\n' "$message"
}

record_restore_action() {
    message=$1
    if [ -d "$STATE_DIR" ]; then
        printf '%s\n' "$message" >> "$RESTORE_ACTIONS_FILE" 2>/dev/null || true
    fi
    log "$message"
}

mark_failure() {
    RESTORE_FAILURES=$((RESTORE_FAILURES + 1))
    record_restore_action "FAILED: $1"
}

# Run a command that may require administrator privileges. sudo is used only when
# the current user is not root and the restore command requires elevated rights.
run_privileged() {
    reason=$1
    shift

    RESTORE_ATTEMPTS=$((RESTORE_ATTEMPTS + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "DRY RUN: would run: $*"
        return 0
    fi

    record_restore_action "Running: $*"
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        "$@"
    else
        printf 'sudo is required to %s. Command: %s\n' "$reason" "$*"
        sudo "$@"
    fi
}

performance_on_disabled_time_machine() {
    [ -f "$ACTIONS_FILE" ] && grep 'Paused Time Machine automatic backups with tmutil disable\.' "$ACTIONS_FILE" >/dev/null 2>&1
}

performance_on_disabled_spotlight() {
    [ -f "$ACTIONS_FILE" ] && grep 'Paused Spotlight indexing on the boot volume with mdutil -i off /\.' "$ACTIONS_FILE" >/dev/null 2>&1
}

prepare_restore_log() {
    if [ -d "$STATE_DIR" ]; then
        : > "$LOG_FILE" 2>/dev/null || true
        : > "$RESTORE_ACTIONS_FILE" 2>/dev/null || true
    fi
}

# Restore pmset values from the generated restore hints. The file is intentionally
# parsed conservatively instead of executed as a shell script.
restore_pmset() {
    if [ ! -s "$PMSET_RESTORE_FILE" ]; then
        record_restore_action "Skipped pmset restore: saved pmset restore file is missing or empty."
        return 0
    fi
    if ! command_exists pmset && [ "$DRY_RUN" -ne 1 ]; then
        record_restore_action "Skipped pmset restore: pmset not found."
        return 0
    fi
    if ! command_exists pmset && [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "Dry run: pmset is not available here, but saved pmset commands will be listed."
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
            'pmset -c sleep '*|'pmset -c displaysleep '*)
                # shellcheck disable=SC2086
                if ! run_privileged "restore saved power management settings" $line; then
                    mark_failure "pmset restore command failed: $line"
                fi
                ;;
            *)
                record_restore_action "Skipped unrecognized pmset restore line: $line"
                ;;
        esac
    done < "$PMSET_RESTORE_FILE"
}

# Re-enable Time Machine automatic backups only if performance_on.sh disabled it.
restore_time_machine() {
    if ! performance_on_disabled_time_machine; then
        record_restore_action "Skipped Time Machine restore: Performance Mode did not record disabling automatic backups."
        return 0
    fi
    if [ ! -s "$TMUTIL_STATE_FILE" ]; then
        record_restore_action "Time Machine state file is missing; attempting restore because disable action was recorded."
    fi
    if ! command_exists tmutil && [ "$DRY_RUN" -ne 1 ]; then
        record_restore_action "Skipped Time Machine restore: tmutil not found."
        return 0
    fi
    if ! command_exists tmutil && [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "Dry run: tmutil is not available here, but Time Machine enable would be attempted on macOS."
    fi

    if ! run_privileged "re-enable Time Machine automatic backups" tmutil enable; then
        mark_failure "tmutil enable failed."
    elif [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "DRY RUN: would re-enable Time Machine automatic backups with tmutil enable."
    else
        record_restore_action "Re-enabled Time Machine automatic backups with tmutil enable."
    fi
}

# Re-enable Spotlight indexing on the boot volume only if performance_on.sh disabled it.
restore_spotlight() {
    if ! performance_on_disabled_spotlight; then
        record_restore_action "Skipped Spotlight restore: Performance Mode did not record disabling boot-volume indexing."
        return 0
    fi
    if [ ! -s "$MDUTIL_STATE_FILE" ]; then
        record_restore_action "Spotlight state file is missing; attempting restore because disable action was recorded."
    fi
    if ! command_exists mdutil && [ "$DRY_RUN" -ne 1 ]; then
        record_restore_action "Skipped Spotlight restore: mdutil not found."
        return 0
    fi
    if ! command_exists mdutil && [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "Dry run: mdutil is not available here, but Spotlight indexing enable would be attempted on macOS."
    fi

    if ! run_privileged "re-enable Spotlight indexing on the boot volume" mdutil -i on /; then
        mark_failure "mdutil -i on / failed."
    elif [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "DRY RUN: would re-enable Spotlight indexing on the boot volume with mdutil -i on /."
    else
        record_restore_action "Re-enabled Spotlight indexing on the boot volume with mdutil -i on /."
    fi
}

restore_app_priority() {
    if [ ! -d "$APP_PRIORITY_STATE_DIR" ]; then
        record_restore_action "Skipped App Priority restore: no saved app-priority state exists."
        return 0
    fi
    if [ ! -x "$APP_PRIORITY_RESTORE_SCRIPT" ] && [ ! -f "$APP_PRIORITY_RESTORE_SCRIPT" ]; then
        mark_failure "App Priority restore script is missing: $APP_PRIORITY_RESTORE_SCRIPT"
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "Running App Priority restore dry run."
        if ! /bin/sh "$APP_PRIORITY_RESTORE_SCRIPT" --dry-run --yes; then
            mark_failure "App Priority restore dry run failed."
            return 1
        fi
        return 0
    fi

    record_restore_action "Running App Priority restore for saved selected-process priority changes."
    if ! /bin/sh "$APP_PRIORITY_RESTORE_SCRIPT" --yes; then
        mark_failure "App Priority restore failed. Continuing with other Performance Mode OFF restore actions."
        return 1
    fi
    record_restore_action "App Priority restore completed."
}

remove_on_marker_after_success() {
    if [ "$DRY_RUN" -eq 1 ]; then
        record_restore_action "DRY RUN: would keep ON marker unchanged: $MARKER_FILE"
        return 0
    fi
    if [ "$RESTORE_FAILURES" -ne 0 ]; then
        record_restore_action "Keeping ON marker because one or more restore actions failed. Retry after resolving the failure."
        return 1
    fi
    if [ -e "$MARKER_FILE" ]; then
        rm -f "$MARKER_FILE" && record_restore_action "Removed Performance Mode ON marker at $MARKER_FILE."
    else
        record_restore_action "ON marker was already absent."
    fi
}

print_summary() {
    printf '\nPerformance Mode OFF summary\n'
    printf 'State directory: %s\n' "$STATE_DIR"
    printf 'Log file: %s\n' "$LOG_FILE"
    printf 'Restore attempts: %s\n' "$RESTORE_ATTEMPTS"
    printf 'Restore failures: %s\n' "$RESTORE_FAILURES"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'Dry run: no settings were changed and the ON marker was not removed.\n'
    elif [ "$RESTORE_FAILURES" -eq 0 ]; then
        printf 'Result: restore actions completed; Performance Mode marker is removed.\n'
    else
        printf 'Result: restore failures were reported; saved state and marker were kept for retry.\n'
    fi

    printf '\nActions restored or skipped:\n'
    if [ -s "$RESTORE_ACTIONS_FILE" ]; then
        sed 's/^/- /' "$RESTORE_ACTIONS_FILE"
    else
        printf '- No restore actions were recorded.\n'
    fi
}

if [ ! -d "$STATE_DIR" ]; then
    printf 'Saved state directory is missing: %s\n' "$STATE_DIR" >&2
    if [ "$FORCE" -ne 1 ]; then
        printf 'Performance Mode does not appear to be ON. Use --force to run anyway.\n' >&2
        exit 1
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || true
fi

prepare_restore_log

if [ ! -e "$MARKER_FILE" ] && [ "$FORCE" -ne 1 ]; then
    log "Performance Mode does not appear to be ON ($MARKER_FILE is missing)."
    log "Refusing to run. Use --force only if you want to attempt restoration from saved state."
    exit 1
fi

if ! is_macos; then
    log "Non-macOS platform detected; macOS-specific restore commands will be skipped if unavailable."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    record_restore_action "Dry run requested; no settings will be changed."
fi

restore_pmset
restore_time_machine
restore_spotlight
restore_app_priority || true
remove_on_marker_after_success || true
print_summary

if [ "$RESTORE_FAILURES" -ne 0 ]; then
    exit 1
fi
exit 0
