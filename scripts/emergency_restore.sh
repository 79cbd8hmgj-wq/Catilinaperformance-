#!/bin/sh
# Emergency fallback restore for CatalinaPerformance.
#
# Safety model:
# - Restores conservative macOS defaults without requiring saved Performance Mode state.
# - Does not modify SIP, delete caches, unload random services, touch fan control,
#   undervolt, load kexts, or use experimental CPU/MSR changes.
# - Uses sudo only for macOS commands that normally require administrator rights.
# - Removes the Performance Mode ON marker only after all restoration attempts finish.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state"
LOG_FILE="$STATE_DIR/emergency_restore.log"
MARKER_FILE="$STATE_DIR/performance_mode_on"

DRY_RUN=0
ASSUME_YES=0
ATTEMPTED=0
SUCCEEDED=0
FAILED=0
SKIPPED=0
ATTEMPTED_LIST=""
SUCCEEDED_LIST=""
FAILED_LIST=""
SKIPPED_LIST=""
LOG_AVAILABLE=0

usage() {
    cat <<USAGE
Usage: $0 [--dry-run] [--yes]

Emergency fallback restore for CatalinaPerformance.

Options:
  --dry-run  Show what would happen without changing settings or removing markers.
  --yes      Skip the interactive confirmation prompt.

This script may use sudo only where macOS normally requires administrator
privileges: tmutil enable, mdutil -i on /, pmset -c, and marker removal if the
state directory is not writable by the current user.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Command lookup helper used before macOS-specific restore commands.
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Platform detection keeps this safe on non-macOS systems and CI hosts.
is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

# Best-effort log setup. Missing or unwritable state directories must not block
# emergency restoration, so logging degrades gracefully to terminal output.
prepare_log() {
    if [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null; then
        if : >> "$LOG_FILE" 2>/dev/null; then
            LOG_AVAILABLE=1
            chmod 700 "$STATE_DIR" 2>/dev/null || true
        fi
    fi
}

log() {
    message=$1
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'unknown-time')
    if [ "$LOG_AVAILABLE" -eq 1 ]; then
        printf '%s %s\n' "$timestamp" "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    printf '%s\n' "$message"
}

append_list() {
    var_name=$1
    item=$2
    eval "current=\${$var_name}"
    if [ -n "$current" ]; then
        eval "$var_name=\${current}\$(printf '\n- %s' \"\$item\")"
    else
        eval "$var_name=\$(printf -- '- %s' \"\$item\")"
    fi
}

record_attempt() {
    ATTEMPTED=$((ATTEMPTED + 1))
    append_list ATTEMPTED_LIST "$1"
    log "Attempting: $1"
}

record_success() {
    SUCCEEDED=$((SUCCEEDED + 1))
    append_list SUCCEEDED_LIST "$1"
    log "Succeeded: $1"
}

record_failure() {
    FAILED=$((FAILED + 1))
    append_list FAILED_LIST "$1"
    log "FAILED: $1"
}

record_skip() {
    SKIPPED=$((SKIPPED + 1))
    append_list SKIPPED_LIST "$1"
    log "Skipped: $1"
}

# Run an administrator-level restore command. sudo is used only when the current
# user is not root and the target macOS command normally requires privileges.
run_privileged() {
    reason=$1
    shift

    if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would run: $*"
        return 0
    fi

    log "Running: $*"
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        "$@"
    else
        printf 'sudo is required to %s. Command: %s\n' "$reason" "$*"
        sudo "$@"
    fi
}

confirm_intent() {
    cat <<WARNING
CatalinaPerformance emergency restore fallback

WARNING: This is a fallback restore tool for cases where performance_off.sh fails
or saved Performance Mode state is missing. It does not rely completely on saved
state. Instead, it attempts conservative normal macOS behavior:
- re-enable Time Machine automatic backups when tmutil is available;
- re-enable Spotlight indexing on the boot volume when mdutil is available;
- restore conservative AC power defaults with pmset where possible.

It will not delete caches, modify SIP, touch fan control, enable or disable
random launch daemons, change hardware-specific settings, undervolt, load kexts,
or use MSR/experimental CPU code.
WARNING

    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'Dry run requested: no settings will be changed.\n'
    fi
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf 'Continuing because --yes was provided.\n'
        return 0
    fi

    printf 'Continue with emergency restore? Type "RESTORE" to proceed: '
    read answer
    if [ "$answer" != "RESTORE" ]; then
        printf 'Aborted. No changes were made.\n'
        exit 1
    fi
}

# Re-enable Time Machine automatic backups. This is a conservative default for
# normal macOS behavior and does not delete backup data.
restore_time_machine() {
    if ! is_macos; then
        record_skip "Time Machine restore: not running on macOS."
        return 0
    fi
    if ! command_exists tmutil; then
        record_skip "Time Machine restore: tmutil not found."
        return 0
    fi

    record_attempt "Re-enable Time Machine automatic backups with tmutil enable."
    if run_privileged "re-enable Time Machine automatic backups" tmutil enable; then
        record_success "Time Machine automatic backups enabled or already enabled."
    else
        record_failure "tmutil enable failed."
    fi
}

# Re-enable Spotlight indexing on the boot volume only. This avoids touching
# unrelated volumes and restores the standard searchable boot volume behavior.
restore_spotlight() {
    if ! is_macos; then
        record_skip "Spotlight restore: not running on macOS."
        return 0
    fi
    if ! command_exists mdutil; then
        record_skip "Spotlight restore: mdutil not found."
        return 0
    fi

    record_attempt "Re-enable Spotlight indexing on the boot volume with mdutil -i on /."
    if run_privileged "re-enable Spotlight indexing on the boot volume" mdutil -i on /; then
        record_success "Spotlight indexing enabled or already enabled on /."
    else
        record_failure "mdutil -i on / failed."
    fi
}

# Restore conservative AC power defaults on macOS Catalina. These defaults favor
# normal system behavior over Performance Mode's no-sleep posture.
restore_pmset_ac_defaults() {
    if ! is_macos; then
        record_skip "pmset restore: not running on macOS."
        return 0
    fi
    if ! command_exists pmset; then
        record_skip "pmset restore: pmset not found."
        return 0
    fi

    record_attempt "Restore conservative AC pmset defaults: sleep=10, displaysleep=10, disksleep=10."
    if run_privileged "restore conservative AC power management defaults" pmset -c sleep 10 displaysleep 10 disksleep 10; then
        record_success "Conservative AC pmset defaults applied."
    else
        record_failure "pmset conservative AC defaults failed."
    fi
}

# Remove only the local Performance Mode marker, and only after restoration
# attempts are complete. This does not delete saved state or user data.
remove_marker_after_attempts() {
    if [ "$DRY_RUN" -eq 1 ]; then
        record_skip "Performance Mode ON marker removal: dry run, marker unchanged."
        return 0
    fi
    if [ ! -e "$MARKER_FILE" ]; then
        record_skip "Performance Mode ON marker removal: marker already absent."
        return 0
    fi

    record_attempt "Remove Performance Mode ON marker after restore attempts."
    if rm -f "$MARKER_FILE" 2>/dev/null; then
        record_success "Removed Performance Mode ON marker."
    elif [ "$(id -u 2>/dev/null || printf 1)" != "0" ] && command_exists sudo; then
        log "sudo is required to remove the marker because it is not writable by the current user. Command: rm -f $MARKER_FILE"
        if sudo rm -f "$MARKER_FILE"; then
            record_success "Removed Performance Mode ON marker with sudo."
        else
            record_failure "Unable to remove Performance Mode ON marker with sudo."
        fi
    else
        record_failure "Unable to remove Performance Mode ON marker."
    fi
}

print_summary() {
    printf '\nEmergency restore summary\n'
    printf 'State directory: %s\n' "$STATE_DIR"
    if [ "$LOG_AVAILABLE" -eq 1 ]; then
        printf 'Log file: %s\n' "$LOG_FILE"
    else
        printf 'Log file: unavailable (could not create or write %s)\n' "$LOG_FILE"
    fi
    printf 'Attempted: %s\n' "$ATTEMPTED"
    printf 'Succeeded: %s\n' "$SUCCEEDED"
    printf 'Failed: %s\n' "$FAILED"
    printf 'Skipped: %s\n' "$SKIPPED"

    printf '\nAttempted actions:\n'
    if [ -n "$ATTEMPTED_LIST" ]; then printf '%s\n' "$ATTEMPTED_LIST"; else printf '%s\n' '- None'; fi
    printf '\nSuccessful actions:\n'
    if [ -n "$SUCCEEDED_LIST" ]; then printf '%s\n' "$SUCCEEDED_LIST"; else printf '%s\n' '- None'; fi
    printf '\nFailed actions:\n'
    if [ -n "$FAILED_LIST" ]; then printf '%s\n' "$FAILED_LIST"; else printf '%s\n' '- None'; fi
    printf '\nSkipped actions:\n'
    if [ -n "$SKIPPED_LIST" ]; then printf '%s\n' "$SKIPPED_LIST"; else printf '%s\n' '- None'; fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\nResult: dry run only; no settings were changed and no marker was removed.\n'
    elif [ "$FAILED" -eq 0 ]; then
        printf '\nResult: emergency restore attempts completed without reported failures.\n'
    else
        printf '\nResult: emergency restore completed with failures; review the summary and log.\n'
    fi
}

prepare_log
log "Starting CatalinaPerformance emergency restore."
if [ ! -d "$STATE_DIR" ]; then
    log "State directory is missing and could not be created; continuing without state files."
fi
if ! is_macos; then
    log "Non-macOS platform detected; macOS-specific commands will be skipped."
fi

confirm_intent
restore_time_machine
restore_spotlight
restore_pmset_ac_defaults
remove_marker_after_attempts
print_summary

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
exit 0
