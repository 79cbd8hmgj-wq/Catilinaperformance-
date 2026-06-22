#!/bin/sh
# Read-only App Priority process report for CatalinaPerformance.
# Lists a small, readable set of user processes without changing anything.

set -u

LIMIT=40

command_exists() { command -v "$1" >/dev/null 2>&1; }
current_user() { id -un 2>/dev/null || printf '%s' "${USER:-unknown}"; }

if [ "$#" -gt 0 ]; then
    case "$1" in
        --help|-h)
            printf 'Usage: %s\n\nLists running user processes with PID, owner, nice value, CPU%%, memory%%, and command. Read-only; no sudo required.\n' "$0"
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
fi

if ! command_exists ps; then
    printf 'ps is not available; cannot build process report.\n' >&2
    exit 1
fi

USER_NAME=$(current_user)
printf 'CatalinaPerformance App Priority process report\n'
printf 'User: %s\n' "$USER_NAME"
printf 'This report is read-only and does not require sudo.\n\n'
printf '%-7s %-16s %-6s %-6s %-6s %s\n' 'PID' 'OWNER' 'NICE' 'CPU%' 'MEM%' 'COMMAND'
printf '%-7s %-16s %-6s %-6s %-6s %s\n' '-------' '----------------' '------' '------' '------' '------------------------------'

# Prefer current-user processes and avoid kernel-only rows. Sort by CPU where ps supports it.
ps -axo pid=,user=,ni=,pcpu=,pmem=,comm= -r 2>/dev/null |
awk -v user="$USER_NAME" -v limit="$LIMIT" '
    $2 == user && $6 != "" && $1 != 0 && $1 != 1 {
        command=$6
        for (i=7; i<=NF; i++) command=command " " $i
        printf "%-7s %-16s %-6s %-6s %-6s %s\n", $1, $2, $3, $4, $5, command
        count++
        if (count >= limit) exit
    }
    END {
        if (count == 0) {
            printf "No current-user processes were reported by ps.\n"
        } else if (count >= limit) {
            printf "\nOutput limited to %s processes. Refresh later if the target is not visible.\n", limit
        }
    }
'

if command_exists osascript; then
    FRONTMOST=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
    if [ -n "$FRONTMOST" ]; then
        printf '\nFrontmost application, if available: %s\n' "$FRONTMOST"
    fi
fi
