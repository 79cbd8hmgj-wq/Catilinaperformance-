#!/bin/sh
# CatalinaPerformance read-only Memory / Storage report.
# This script intentionally does not use sudo, delete files, clear caches,
# change memory behavior, or modify system settings.

set -u

PREFERENCES_FILE=${CATALINA_PERFORMANCE_PREFERENCES_FILE:-"$HOME/Library/Application Support/CatalinaPerformance/advanced_preferences.env"}

pref_enabled() {
    name=$1
    default=$2
    value=$default
    if [ -f "$PREFERENCES_FILE" ]; then
        line=$(sed -n "s/^${name}=//p" "$PREFERENCES_FILE" 2>/dev/null | tail -n 1)
        case "$line" in
            0|1) value=$line ;;
        esac
    fi
    [ "$value" = "1" ]
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

print_section() {
    printf '\n== %s ==\n' "$1"
}

warn() {
    printf 'WARNING: %s\n' "$1"
}

ok() {
    printf 'OK: %s\n' "$1"
}

printf 'CatalinaPerformance Memory / Storage Check (read-only)\n'
printf 'No cleanup, deletion, memory tuning, or system setting changes are performed.\n'
printf 'Thresholds: swap warning above 1024 MB used; disk warning below 10%% free or below 10 GB free; memory pressure warning when macOS reports warn/critical.\n'

if pref_enabled SHOW_SWAP_USAGE_WARNING 1; then
    print_section "Swap Usage"
    if have_command sysctl; then
        swap_line=$(sysctl -n vm.swapusage 2>/dev/null || true)
        if [ -n "$swap_line" ]; then
            printf '%s\n' "$swap_line"
            used_mb=$(printf '%s\n' "$swap_line" | awk '{ for (i = 1; i <= NF; i++) if ($i == "used") { gsub("M", "", $(i + 2)); print int($(i + 2)); exit } }')
            if [ -n "$used_mb" ]; then
                if [ "$used_mb" -gt 1024 ]; then
                    warn "Swap used is ${used_mb} MB, above the conservative 1024 MB warning threshold."
                else
                    ok "Swap used is ${used_mb} MB, at or below the 1024 MB warning threshold."
                fi
            else
                printf 'Unable to parse swap usage from sysctl output.\n'
            fi
        else
            printf 'Swap usage is unavailable from sysctl vm.swapusage on this system.\n'
        fi
    else
        printf 'sysctl command not found; swap usage unavailable.\n'
    fi
else
    print_section "Swap Usage"
    printf 'Skipped because Show swap usage warning is disabled in Advanced preferences.\n'
fi

if pref_enabled SHOW_LOW_DISK_SPACE_WARNING 1; then
    print_section "Disk Free Space"
    disk_path=${CATALINA_PERFORMANCE_DISK_PATH:-$HOME}
    if have_command df; then
        df_line=$(df -Pk "$disk_path" 2>/dev/null | awk 'NR == 2 { print }')
        if [ -n "$df_line" ]; then
            printf 'Path checked: %s\n' "$disk_path"
            printf '%s\n' "$(df -Pk "$disk_path" 2>/dev/null)"
            available_kb=$(printf '%s\n' "$df_line" | awk '{ print $4 }')
            capacity=$(printf '%s\n' "$df_line" | awk '{ print $5 }' | tr -d '%')
            if [ -n "$available_kb" ] && [ -n "$capacity" ]; then
                free_percent=$((100 - capacity))
                available_gb=$((available_kb / 1024 / 1024))
                if [ "$free_percent" -lt 10 ] || [ "$available_gb" -lt 10 ]; then
                    warn "Free disk space is low (${free_percent}% free, about ${available_gb} GB available)."
                else
                    ok "Disk free space is ${free_percent}% free, about ${available_gb} GB available."
                fi
            else
                printf 'Unable to parse df output.\n'
            fi
        else
            printf 'Disk free space is unavailable for %s.\n' "$disk_path"
        fi
    else
        printf 'df command not found; disk free space unavailable.\n'
    fi
else
    print_section "Disk Free Space"
    printf 'Skipped because Show low disk space warning is disabled in Advanced preferences.\n'
fi

if pref_enabled SHOW_MEMORY_PRESSURE_SUMMARY 1; then
    print_section "Memory Pressure"
    if have_command memory_pressure; then
        pressure_output=$(memory_pressure 2>/dev/null || true)
        if [ -n "$pressure_output" ]; then
            printf '%s\n' "$pressure_output" | sed -n '1,12p'
            if printf '%s\n' "$pressure_output" | awk '{ line=tolower($0); if (line ~ /critical|warn/) found=1 } END { exit found ? 0 : 1 }'; then
                warn "Memory pressure appears elevated according to memory_pressure output."
            else
                ok "No warn or critical memory pressure state was detected."
            fi
        else
            printf 'memory_pressure returned no output.\n'
        fi
    else
        printf 'memory_pressure command not found; memory pressure summary unavailable.\n'
    fi
else
    print_section "Memory Pressure"
    printf 'Skipped because Show memory pressure summary is disabled in Advanced preferences.\n'
fi

if pref_enabled SHOW_TOP_MEMORY_PROCESSES 1; then
    print_section "Top Memory-Heavy Processes"
    if have_command ps; then
        ps -axo pid,comm,%mem,rss 2>/dev/null | awk 'NR == 1 { print; next } { print | "sort -k3 -nr" }' | sed -n '1,11p' || printf 'Unable to read process list.\n'
        printf 'RSS is shown in KB as reported by ps.\n'
    else
        printf 'ps command not found; process summary unavailable.\n'
    fi
else
    print_section "Top Memory-Heavy Processes"
    printf 'Skipped because Show top memory-heavy processes is disabled in Advanced preferences.\n'
fi

print_section "Top Disk-Heavy Folders"
printf 'Optional folder scan is not run automatically. Future versions may add a read-only manual scan; no deletion or cleanup is implemented.\n'

print_section "Cleanup Tools"
printf 'Cache cleanup tools: Not implemented yet — future manual-only feature.\n'
printf 'Browser cache cleanup: Not implemented yet — future manual-only feature.\n'
printf 'Automatic cleanup: Disabled and discouraged; CatalinaPerformance does not perform automatic cleanup.\n'
