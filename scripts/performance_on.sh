#!/bin/sh
# Turn CatalinaPerformance Performance Mode ON.
#
# Safety model:
# - Records current state in .catalina_performance_state/ before changing settings.
# - Uses reversible macOS commands only.
# - Does not modify SIP, delete caches, unload launch daemons, touch fan control,
#   undervolt, load kexts, or use experimental CPU/MSR changes.
# - Intended restore companion: scripts/performance_off.sh should read this state
#   directory and restore the saved values.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)
STATE_DIR="$REPO_ROOT/.catalina_performance_state"
LOG_FILE="$STATE_DIR/performance_on.log"
MARKER_FILE="$STATE_DIR/performance_mode_on"
PMSET_CUSTOM_FILE="$STATE_DIR/pmset_custom_before.txt"
PMSET_ACTIVE_FILE="$STATE_DIR/pmset_active_before.txt"
PMSET_RESTORE_FILE="$STATE_DIR/pmset_restore_commands.sh"
TMUTIL_STATE_FILE="$STATE_DIR/timemachine_before.txt"
MDUTIL_STATE_FILE="$STATE_DIR/spotlight_boot_before.txt"
ACTIONS_FILE="$STATE_DIR/actions_taken.txt"
PREFERENCES_FILE="${CATALINA_PERFORMANCE_PREFERENCES_FILE:-${HOME:-}/Library/Application Support/CatalinaPerformance/advanced_preferences.env}"
PAUSE_SPOTLIGHT_WHILE_ON=1
PAUSE_TIME_MACHINE_WHILE_ON=1
PREVENT_SYSTEM_SLEEP_WHILE_ON=1
PREVENT_DISPLAY_SLEEP_WHILE_ON=1

FORCE=0
ASSUME_YES=0

usage() {
    cat <<USAGE
Usage: $0 [--force] [--yes]

Turns CatalinaPerformance Performance Mode ON.

Options:
  --force  Run even if Performance Mode already appears to be ON.
  --yes    Skip the interactive confirmation prompt.

This script may use sudo for reversible macOS power, Time Machine, and
Spotlight changes when the current user is not root.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

log() {
    message=$1
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf 'unknown-time')
    printf '%s %s\n' "$timestamp" "$message" | tee -a "$LOG_FILE" >/dev/null
}

record_action() {
    printf '%s\n' "$1" >> "$ACTIONS_FILE"
    log "$1"
}

read_boolean_preference() {
    key=$1
    default_value=$2

    if [ ! -f "$PREFERENCES_FILE" ]; then
        printf '%s' "$default_value"
        return 0
    fi

    value=$(awk -F= -v wanted="$key" '
        /^[[:space:]]*($|#)/ { next }
        $1 == wanted {
            value=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$PREFERENCES_FILE" 2>/dev/null || printf '')

    case "$value" in
        1|true|TRUE|yes|YES|on|ON) printf '1' ;;
        0|false|FALSE|no|NO|off|OFF) printf '0' ;;
        '')
            log "Warning: Advanced preferences file $PREFERENCES_FILE is missing key $key; defaulting to enabled."
            printf '%s' "$default_value"
            ;;
        *)
            log "Warning: Advanced preferences file $PREFERENCES_FILE has invalid value for $key; defaulting to enabled."
            printf '%s' "$default_value"
            ;;
    esac
}

validate_preferences_file() {
    if [ ! -f "$PREFERENCES_FILE" ]; then
        log "Advanced preferences file not found at $PREFERENCES_FILE; defaulting configurable Advanced actions to enabled."
        return 0
    fi

    awk -F= '
        /^[[:space:]]*($|#)/ { next }
        $1 == "PAUSE_SPOTLIGHT_WHILE_ON" || \
        $1 == "PAUSE_TIME_MACHINE_WHILE_ON" || \
        $1 == "PREVENT_SYSTEM_SLEEP_WHILE_ON" || \
        $1 == "PREVENT_DISPLAY_SLEEP_WHILE_ON" { next }
        { bad=1 }
        END { exit bad ? 1 : 0 }
    ' "$PREFERENCES_FILE" 2>/dev/null || log "Warning: Advanced preferences file $PREFERENCES_FILE contains malformed or unknown entries; only known keys will be read."
}

load_preferences() {
    validate_preferences_file
    PAUSE_SPOTLIGHT_WHILE_ON=$(read_boolean_preference PAUSE_SPOTLIGHT_WHILE_ON 1)
    PAUSE_TIME_MACHINE_WHILE_ON=$(read_boolean_preference PAUSE_TIME_MACHINE_WHILE_ON 1)
    PREVENT_SYSTEM_SLEEP_WHILE_ON=$(read_boolean_preference PREVENT_SYSTEM_SLEEP_WHILE_ON 1)
    PREVENT_DISPLAY_SLEEP_WHILE_ON=$(read_boolean_preference PREVENT_DISPLAY_SLEEP_WHILE_ON 1)
    log "Advanced preferences: Pause Spotlight=$PAUSE_SPOTLIGHT_WHILE_ON, Pause Time Machine=$PAUSE_TIME_MACHINE_WHILE_ON, Prevent system sleep=$PREVENT_SYSTEM_SLEEP_WHILE_ON, Prevent display sleep=$PREVENT_DISPLAY_SLEEP_WHILE_ON."
}

run_privileged() {
    reason=$1
    shift

    log "About to run: $*"
    if [ "$(id -u 2>/dev/null || printf 1)" = "0" ]; then
        "$@"
    else
        printf 'sudo is required to %s. Command: %s\n' "$reason" "$*"
        sudo "$@"
    fi
}

read_pmset_value() {
    key=$1
    file=$2
    awk -v wanted="$key" '$1 == wanted { print $2; found=1 } END { if (!found) exit 1 }' "$file" 2>/dev/null
}

prepare_state_dir() {
    mkdir -p "$STATE_DIR"
    : > "$LOG_FILE"
    : > "$ACTIONS_FILE"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    log "State directory: $STATE_DIR"
}

confirm_intent() {
    cat <<WARNING
CatalinaPerformance will turn Performance Mode ON.

Planned reversible changes on macOS, when the required commands exist and Advanced preferences allow them:
- Save current pmset settings, then optionally prevent system sleep while plugged in.
- Optionally prevent display sleep while Performance Mode is active.
- Optionally pause Time Machine automatic backups.
- Optionally pause Spotlight indexing on the boot volume.

This script will not modify SIP, delete caches, permanently disable services,
touch fan control, undervolt, use MSR code, load kexts, or install third-party tools.
WARNING

    if [ "$ASSUME_YES" -eq 1 ]; then
        printf 'Continuing because --yes was provided.\n'
        return 0
    fi

    printf 'Continue? Type "ON" to proceed: '
    read answer
    if [ "$answer" != "ON" ]; then
        printf 'Aborted. No changes were made.\n'
        exit 1
    fi
}

save_pmset_state() {
    if ! command_exists pmset; then
        record_action "Skipped pmset changes: pmset not found."
        return 0
    fi

    pmset -g custom > "$PMSET_CUSTOM_FILE" 2>&1 || pmset -g > "$PMSET_CUSTOM_FILE" 2>&1 || {
        record_action "Skipped pmset changes: unable to read current pmset settings."
        return 0
    }
    pmset -g > "$PMSET_ACTIVE_FILE" 2>&1 || true
    record_action "Saved original pmset settings to $PMSET_CUSTOM_FILE and $PMSET_ACTIVE_FILE."

    current_sleep=$(read_pmset_value sleep "$PMSET_ACTIVE_FILE" || printf '')
    current_displaysleep=$(read_pmset_value displaysleep "$PMSET_ACTIVE_FILE" || printf '')

    {
        printf '#!/bin/sh\n'
        printf '# Generated before enabling Performance Mode. Intended for performance_off.sh.\n'
        if [ "$PREVENT_SYSTEM_SLEEP_WHILE_ON" = "1" ] && [ -n "$current_sleep" ]; then
            printf 'pmset -c sleep %s\n' "$current_sleep"
        fi
        if [ "$PREVENT_DISPLAY_SLEEP_WHILE_ON" = "1" ] && [ -n "$current_displaysleep" ]; then
            printf 'pmset -c displaysleep %s\n' "$current_displaysleep"
        fi
    } > "$PMSET_RESTORE_FILE"
    chmod 600 "$PMSET_RESTORE_FILE" 2>/dev/null || true
    record_action "Wrote pmset restore hints to $PMSET_RESTORE_FILE."
}

apply_pmset_changes() {
    if ! command_exists pmset || [ ! -s "$PMSET_CUSTOM_FILE" ]; then
        return 0
    fi

    pmset_args=""
    if [ "$PREVENT_SYSTEM_SLEEP_WHILE_ON" = "1" ]; then
        pmset_args="$pmset_args sleep 0"
    else
        record_action "Skipped plugged-in system sleep change: Advanced preference disabled by user."
    fi
    if [ "$PREVENT_DISPLAY_SLEEP_WHILE_ON" = "1" ]; then
        pmset_args="$pmset_args displaysleep 0"
    else
        record_action "Skipped display sleep change: Advanced preference disabled by user."
    fi

    if [ -z "$pmset_args" ]; then
        return 0
    fi

    # shellcheck disable=SC2086
    run_privileged "apply selected plugged-in power-management preferences" pmset -c $pmset_args
    record_action "Changed pmset AC power settings:$pmset_args."
}

save_time_machine_state() {
    if [ "$PAUSE_TIME_MACHINE_WHILE_ON" != "1" ]; then
        record_action "Skipped Time Machine pause: Advanced preference disabled by user."
        return 0
    fi

    if ! command_exists tmutil; then
        record_action "Skipped Time Machine pause: tmutil not found."
        return 0
    fi

    {
        printf 'tmutil status before Performance Mode:\n'
        tmutil status 2>&1 || true
        printf '\nAutoBackup preference before Performance Mode:\n'
        if command_exists defaults; then
            defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>&1 || true
        else
            printf 'defaults command unavailable\n'
        fi
    } > "$TMUTIL_STATE_FILE"
    record_action "Saved Time Machine state to $TMUTIL_STATE_FILE."
}

pause_time_machine() {
    if [ "$PAUSE_TIME_MACHINE_WHILE_ON" != "1" ]; then
        log "Skipped Time Machine pause because the Advanced preference is disabled."
        return 0
    fi

    if ! command_exists tmutil || [ ! -s "$TMUTIL_STATE_FILE" ]; then
        return 0
    fi

    run_privileged "pause Time Machine automatic backups reversibly" tmutil disable
    record_action "Paused Time Machine automatic backups with tmutil disable."
}

save_spotlight_state() {
    if [ "$PAUSE_SPOTLIGHT_WHILE_ON" != "1" ]; then
        record_action "Skipped Spotlight pause: Advanced preference disabled by user."
        return 0
    fi

    if ! command_exists mdutil; then
        record_action "Skipped Spotlight pause: mdutil not found."
        return 0
    fi

    mdutil -s / > "$MDUTIL_STATE_FILE" 2>&1 || true
    record_action "Saved Spotlight indexing state for / to $MDUTIL_STATE_FILE."
}

pause_spotlight() {
    if [ "$PAUSE_SPOTLIGHT_WHILE_ON" != "1" ]; then
        log "Skipped Spotlight pause because the Advanced preference is disabled."
        return 0
    fi

    if ! command_exists mdutil || [ ! -s "$MDUTIL_STATE_FILE" ]; then
        return 0
    fi

    run_privileged "pause Spotlight indexing on the boot volume reversibly" mdutil -i off /
    record_action "Paused Spotlight indexing on the boot volume with mdutil -i off /."
}

print_summary() {
    printf '\nPerformance Mode ON summary\n'
    printf 'State directory: %s\n' "$STATE_DIR"
    printf 'Log file: %s\n' "$LOG_FILE"
    printf '\nActions taken:\n'
    if [ -s "$ACTIONS_FILE" ]; then
        sed 's/^/- /' "$ACTIONS_FILE"
    else
        printf '- No changes were made.\n'
    fi
    printf '\nTo restore later, performance_off.sh should use the saved state files in %s.\n' "$STATE_DIR"
}

prepare_state_dir

if [ -e "$MARKER_FILE" ] && [ "$FORCE" -ne 1 ]; then
    printf 'Performance Mode already appears to be ON (%s exists).\n' "$MARKER_FILE" >&2
    printf 'Refusing to run. Use --force only if you have verified the saved state is safe to overwrite.\n' >&2
    exit 1
fi

if ! is_macos; then
    log "Non-macOS platform detected; macOS-specific changes will be skipped if commands are unavailable."
fi

load_preferences
confirm_intent
save_pmset_state
save_time_machine_state
save_spotlight_state
apply_pmset_changes
pause_time_machine
pause_spotlight

{
    printf 'enabled_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || printf unknown)"
    printf 'script=%s\n' "$0"
} > "$MARKER_FILE"
record_action "Created Performance Mode ON marker at $MARKER_FILE."

print_summary
