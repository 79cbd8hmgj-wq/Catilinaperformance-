#!/bin/sh
# Read-only CatalinaPerformance App Priority process report.
# Lists a small set of user-owned running processes without changing state.

set -u

LIMIT=80
CURRENT_USER=$(id -un 2>/dev/null || printf '')

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_macos() { [ "$(uname -s 2>/dev/null)" = "Darwin" ]; }

printf 'CatalinaPerformance App Priority process report\n'
printf 'Read-only: no processes are changed. Sudo is not required.\n'
if ! is_macos; then
    printf 'Note: non-macOS platform detected; using portable ps output where available.\n'
fi
printf '\n'

if ! command_exists ps; then
    printf 'Unable to list processes: ps command not found.\n' >&2
    exit 1
fi

printf 'PID\tNAME\tNICE\tCPU%%\tMEM%%\tOWNER\n'

# Prefer user-owned processes, which is the only class CatalinaPerformance will
# target by default. comm keeps the process name compact for UI display.
ps -axo pid=,user=,nice=,%cpu=,%mem=,comm= 2>/dev/null | awk -v user="$CURRENT_USER" -v limit="$LIMIT" '
BEGIN { count=0 }
{
    pid=$1; owner=$2; nice=$3; cpu=$4; mem=$5;
    name="";
    for (i=6; i<=NF; i++) name = name (name == "" ? "" : " ") $i;
    if (pid == "" || name == "") next;
    if (user != "" && owner != user) next;
    if (pid == 0 || pid == 1) next;
    if (name ~ /(kernel_task|launchd|WindowServer|loginwindow)$/) next;
    printf "%s\t%s\t%s\t%s\t%s\t%s\n", pid, name, nice, cpu, mem, owner;
    count++;
    if (count >= limit) exit;
}
END {
    if (count == 0) {
        printf "No user-owned processes were found in ps output.\n" > "/dev/stderr";
    }
}'
