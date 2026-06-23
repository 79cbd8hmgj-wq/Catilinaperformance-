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

printf 'PID\tNAME\tNICE\tCPU%%\tMEM%%\tOWNER\tSTART\tFULL_COMMAND\n'

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
}' | while IFS=$(printf '\t') read -r pid name nice cpu mem owner; do
    [ -n "$pid" ] || continue
    start_time=$(ps -p "$pid" -o lstart= 2>/dev/null | sed -n '1p' || printf '')
    full_command=$(ps -p "$pid" -o args= 2>/dev/null | sed -n '1p' || printf '')
    # Keep the report tab-delimited for the GUI parser; process arguments with
    # literal tabs are rare and are normalized to spaces for a stable UI field.
    full_command=$(printf '%s' "$full_command" | tr '\t' ' ')
    start_time=$(printf '%s' "$start_time" | tr '\t' ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$name" "$nice" "$cpu" "$mem" "$owner" "$start_time" "$full_command"
done
