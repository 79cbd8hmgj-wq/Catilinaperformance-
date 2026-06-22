#!/bin/sh
# Read-only Memory / Storage report for CatalinaPerformance.
# This script does not require sudo, does not modify settings, and does not delete files.

set -u

SHOW_SWAP=1
SHOW_DISK=1
SHOW_PRESSURE=1
SHOW_TOP_PROCESSES=1
SHOW_TOP_FOLDERS=0

SWAP_WARN_MB=1024
DISK_WARN_PERCENT=15
DISK_WARN_GB=20

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-swap) SHOW_SWAP=0 ;;
        --no-disk) SHOW_DISK=0 ;;
        --no-pressure) SHOW_PRESSURE=0 ;;
        --no-top-processes) SHOW_TOP_PROCESSES=0 ;;
        --top-folders) SHOW_TOP_FOLDERS=1 ;;
        --help)
            cat <<HELP
Usage: memory_storage_report.sh [options]

Read-only CatalinaPerformance Memory / Storage report.
Options disable individual sections: --no-swap, --no-disk, --no-pressure,
--no-top-processes. Optional read-only folder scan: --top-folders.

Warning thresholds are conservative:
- Swap warning: more than ${SWAP_WARN_MB} MB used.
- Disk warning: startup volume has less than ${DISK_WARN_PERCENT}% free or less than ${DISK_WARN_GB} GB free.
- Memory pressure warning: memory_pressure reports warning/critical, or vm_stat free+inactive pages are very low.
HELP
            exit 0
            ;;
        *) printf 'Warning: ignoring unknown option: %s\n' "$1" ;;
    esac
    shift
done

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n== %s ==\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1"; }
ok() { printf 'OK: %s\n' "$1"; }

printf 'CatalinaPerformance Memory / Storage Check\n'
printf 'Read-only report: no sudo, no deletions, no cache cleanup, no settings changes.\n'
printf 'Thresholds: swap > %s MB; disk free < %s%% or < %s GB; elevated memory pressure when reported by macOS.\n' "$SWAP_WARN_MB" "$DISK_WARN_PERCENT" "$DISK_WARN_GB"

if [ "$SHOW_SWAP" -eq 1 ]; then
    section "Swap Usage"
    if have sysctl; then
        swap_line=$(sysctl -n vm.swapusage 2>/dev/null || true)
        if [ -n "$swap_line" ]; then
            printf '%s\n' "$swap_line"
            used_mb=$(printf '%s\n' "$swap_line" | awk '{ for (i=1; i<=NF; i++) if ($i == "used") { v=$(i+2); gsub(/M/, "", v); print int(v); exit } }')
            if [ -n "${used_mb:-}" ] && [ "$used_mb" -gt "$SWAP_WARN_MB" ] 2>/dev/null; then
                warn "Swap used is ${used_mb} MB, above the ${SWAP_WARN_MB} MB warning threshold."
            else
                ok "Swap usage is at or below the conservative warning threshold."
            fi
        else
            printf 'Swap information unavailable from sysctl.\n'
        fi
    else
        printf 'sysctl command not found; swap usage unavailable.\n'
    fi
fi

if [ "$SHOW_DISK" -eq 1 ]; then
    section "Disk Free Space"
    if have df; then
        df -h / 2>/dev/null || printf 'Unable to read disk free space for /.\n'
        line=$(df -k / 2>/dev/null | awk 'NR==2 { print $0 }')
        if [ -n "$line" ]; then
            avail_kb=$(printf '%s\n' "$line" | awk '{ print $4 }')
            capacity=$(printf '%s\n' "$line" | awk '{ print $5 }' | tr -d '%')
            free_percent=$((100 - capacity))
            warn_kb=$((DISK_WARN_GB * 1024 * 1024))
            if [ "$free_percent" -lt "$DISK_WARN_PERCENT" ] 2>/dev/null || [ "$avail_kb" -lt "$warn_kb" ] 2>/dev/null; then
                warn "Startup volume free space is low (${free_percent}% free). Keep cleanup manual; this tool will not delete files."
            else
                ok "Startup volume free space is above the warning threshold."
            fi
        fi
    else
        printf 'df command not found; disk free space unavailable.\n'
    fi
fi

if [ "$SHOW_PRESSURE" -eq 1 ]; then
    section "Memory Pressure"
    if have memory_pressure; then
        pressure_output=$(memory_pressure 2>/dev/null || true)
        if [ -n "$pressure_output" ]; then
            printf '%s\n' "$pressure_output" | sed -n '1,12p'
            if printf '%s\n' "$pressure_output" | awk 'BEGIN{IGNORECASE=1} /critical|warn|pressure.*high|pressure.*elevated/ { found=1 } END{ exit found ? 0 : 1 }'; then
                warn "macOS memory_pressure output appears elevated."
            else
                ok "memory_pressure did not report an elevated state."
            fi
        else
            printf 'memory_pressure returned no output.\n'
        fi
    elif have vm_stat; then
        printf 'memory_pressure command unavailable; using vm_stat summary.\n'
        vm_stat 2>/dev/null | sed -n '1,12p'
    else
        printf 'Neither memory_pressure nor vm_stat was found; memory pressure unavailable.\n'
    fi
fi

if [ "$SHOW_TOP_PROCESSES" -eq 1 ]; then
    section "Top Memory-Heavy Processes"
    if have ps; then
        ps -arcwwwxo pid,comm,%mem,rss | head -n 11 2>/dev/null || printf 'Unable to list top memory processes.\n'
    else
        printf 'ps command not found; process list unavailable.\n'
    fi
fi

if [ "$SHOW_TOP_FOLDERS" -eq 1 ]; then
    section "Top Disk-Heavy Folders (Read-Only Optional Scan)"
    if have du; then
        printf 'Scanning immediate folders in your home directory only; this may take a moment and does not delete anything.\n'
        du -sk "$HOME"/* 2>/dev/null | sort -nr | head -n 10 | awk '{ printf "%.1f GB\t%s\n", $1/1024/1024, $2 }'
    else
        printf 'du command not found; folder scan unavailable.\n'
    fi
fi

printf '\nDone. This report is informational only. Cache cleanup, browser cleanup, and automatic cleanup are not implemented.\n'
