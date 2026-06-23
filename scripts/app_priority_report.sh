#!/bin/sh
# Read-only App Priority report for CatalinaPerformance.
#
# Safety model:
# - Requires no sudo and performs no process mutation.
# - Uses macOS-provided commands only.
# - Lists a bounded view of the current user's processes with priority-related
#   information for monitoring only.

set -u

MAX_ROWS=${CATALINA_APP_PRIORITY_REPORT_MAX_ROWS:-25}

is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

case "$MAX_ROWS" in
    ''|*[!0-9]*) MAX_ROWS=25 ;;
esac
if [ "$MAX_ROWS" -lt 1 ] 2>/dev/null; then
    MAX_ROWS=25
fi
if [ "$MAX_ROWS" -gt 50 ] 2>/dev/null; then
    MAX_ROWS=50
fi

if ! is_macos; then
    printf 'App Priority report is read-only and currently supports macOS only. No process state was changed.\n'
    exit 0
fi

if ! command -v ps >/dev/null 2>&1; then
    printf 'Unable to run App Priority report: ps command not found. No process state was changed.\n' >&2
    exit 1
fi

current_user=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
printf 'App Priority report (read-only monitoring; no sudo; no renice; no process state changed)\n'
printf 'Showing up to %s processes for user: %s\n\n' "$MAX_ROWS" "$current_user"
printf '%s\n' 'PID OWNER NICE CPU% MEM% COMMAND'

# Sort by CPU usage where supported and limit output to avoid excessive GUI logs.
# Fields are intentionally monitoring-only: PID, owner, nice value, CPU %, memory %, and command.
ps -u "$current_user" -o pid= -o user= -o nice= -o %cpu= -o %mem= -o comm= -r 2>/dev/null | head -n "$MAX_ROWS"
ps_status=$?

if [ "$ps_status" -ne 0 ]; then
    printf 'Unable to collect current user process list. No process state was changed.\n' >&2
    exit "$ps_status"
fi

printf '\nReport complete. App Priority mutation is not implemented yet and remains disabled for safety.\n'
