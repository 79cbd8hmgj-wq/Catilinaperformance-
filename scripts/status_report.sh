#!/bin/sh
# Read-only status report for CatalinaPerformance.
# This script prints system information only; it does not change settings,
# use sudo, delete files, unload services, or write configuration.

set -u

print_section() {
    printf '\n== %s ==\n' "$1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_or_unavailable() {
    if command_exists "$1"; then
        "$@" 2>/dev/null || printf 'Unavailable\n'
    else
        printf 'Unavailable (%s not found)\n' "$1"
    fi
}

is_macos() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ]
}

printf '%s\n' "CatalinaPerformance Read-Only Status Report"
printf '%s\n' "Generated: $(date 2>/dev/null || printf 'Unavailable')"
printf '%s\n' "Note: this script only reads system status and does not change settings."

# Report the installed macOS version. sw_vers is the standard macOS version tool.
print_section "macOS Version"
if is_macos && command_exists sw_vers; then
    product_name=$(sw_vers -productName 2>/dev/null || printf 'Unavailable')
    product_version=$(sw_vers -productVersion 2>/dev/null || printf 'Unavailable')
    build_version=$(sw_vers -buildVersion 2>/dev/null || printf 'Unavailable')
    printf 'Product: %s\n' "$product_name"
    printf 'Version: %s\n' "$product_version"
    printf 'Build: %s\n' "$build_version"
else
    printf 'Unavailable (requires macOS sw_vers)\n'
fi

# Report the Mac model identifier, useful for older Intel Mac compatibility notes.
print_section "Mac Model Identifier"
if is_macos && command_exists sysctl; then
    sysctl -n hw.model 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS sysctl)\n'
fi

# Report uptime using the built-in uptime command.
print_section "Uptime"
run_or_unavailable uptime

# Report CPU load averages. uptime includes load averages on macOS.
print_section "CPU Load"
if command_exists uptime; then
    load_text=$(uptime 2>/dev/null | sed 's/^.*load averages*: //; s/^.*load average: //')
    if [ -n "$load_text" ]; then
        printf 'Load averages: %s\n' "$load_text"
    else
        printf 'Unavailable\n'
    fi
else
    printf 'Unavailable (uptime not found)\n'
fi

# Report memory pressure when available. vm_stat is read-only and built into macOS.
print_section "Memory Pressure"
if is_macos && command_exists memory_pressure; then
    memory_pressure 2>/dev/null || printf 'Unavailable\n'
elif is_macos && command_exists vm_stat; then
    printf 'memory_pressure command unavailable; showing vm_stat instead.\n'
    vm_stat 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS memory_pressure or vm_stat)\n'
fi

# Report swap usage when available. sysctl vm.swapusage is read-only on macOS.
print_section "Swap Usage"
if is_macos && command_exists sysctl; then
    sysctl vm.swapusage 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS sysctl)\n'
fi

# Report free disk space for the boot volume. df is read-only.
print_section "Disk Free Space"
if command_exists df; then
    df -h / 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (df not found)\n'
fi

# Report whether the Mac is on battery or AC power. pmset is read-only with -g ps.
print_section "Battery / AC Power Status"
if is_macos && command_exists pmset; then
    pmset -g ps 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS pmset)\n'
fi

# Report current power management settings. pmset -g reads settings only.
print_section "Current pmset Settings"
if is_macos && command_exists pmset; then
    pmset -g 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS pmset)\n'
fi

# Report Time Machine automatic backup status when available.
# defaults read is read-only; tmutil status is also read-only.
print_section "Time Machine Automatic Backup Status"
if is_macos; then
    if command_exists defaults; then
        auto_status=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null || true)
        case "$auto_status" in
            1) printf 'Automatic backups: On\n' ;;
            0) printf 'Automatic backups: Off\n' ;;
            *) printf 'Automatic backup setting unavailable.\n' ;;
        esac
    else
        printf 'Automatic backup setting unavailable (defaults not found).\n'
    fi

    if command_exists tmutil; then
        printf '\nCurrent Time Machine activity:\n'
        tmutil status 2>/dev/null || printf 'tmutil status unavailable.\n'
    else
        printf 'Current Time Machine activity unavailable (tmutil not found).\n'
    fi
else
    printf 'Unavailable (requires macOS defaults/tmutil)\n'
fi

# Report Spotlight indexing status for the boot volume. mdutil -s reads status only.
print_section "Spotlight Indexing Status (Boot Volume)"
if is_macos && command_exists mdutil; then
    mdutil -s / 2>/dev/null || printf 'Unavailable\n'
else
    printf 'Unavailable (requires macOS mdutil)\n'
fi
