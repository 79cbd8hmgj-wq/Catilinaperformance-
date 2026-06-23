# Known Issues

This page tracks current limitations and development notes for CatalinaPerformance.

## macOS Catalina Toolchain Setup

- Older Catalina Macs may need the full Xcode application installed rather than Command Line Tools only.
- `xcrun` may fail to find `xctest` until the full Xcode installation is selected with Xcode's settings or `xcode-select`.

## GUI Limitations

- GUI script output display was previously blank before Patch H. Current manual GUI testing should still verify that script output appears after **Refresh Status**, **Run Performance ON**, **Run Performance OFF**, and **Emergency Restore**.
- GUI sudo/admin handling may still need improvement. Some script actions can require administrator authorization, and the GUI may not yet provide the final intended authorization flow.

## Feature Gaps

- Fan control is not implemented yet.
- Most Advanced options are placeholder-only; only the existing Background Services pause preferences and Power Behavior sleep/display preferences are script-readable via `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`.
- Power Behavior placeholders for disk sleep, Power Nap, and keeping network awake are not implemented.

## Safety Boundaries

CatalinaPerformance should continue to avoid SIP changes, automatic cache deletion, permanent service disablement, launch daemon changes, undervolting, MSR changes, kext changes, and other irreversible or unsafe system modifications.

## App Priority Limitations

- Priority boosting may not noticeably improve every app; CPU, GPU, memory pressure, disk I/O, thermal throttling, or the app's own workload may be the real bottleneck.
- Setting a negative nice value can require administrator authorization on macOS, even for a user-owned process.
- Protected and system processes are intentionally blocked, including critical services such as `launchd`, `kernel_task`, `WindowServer`, `loginwindow`, Spotlight metadata services, backup services, security, audio, network configuration, Bluetooth, and Open Directory services.
- Closed processes cannot be restored because their PIDs no longer exist; CatalinaPerformance logs these skips and preserves state for troubleshooting.
- Process IDs change after relaunch. Saved App Priority selections are lightweight UI preferences only and should not be blindly reused or auto-boosted on app launch.
