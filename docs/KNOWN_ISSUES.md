# Known Issues

This page tracks current limitations and development notes for CatalinaPerformance.

## macOS Catalina Toolchain Setup

- Older Catalina Macs may need the full Xcode application installed rather than Command Line Tools only.
- `xcrun` may fail to find `xctest` until the full Xcode installation is selected with Xcode's settings or `xcode-select`.

## GUI Limitations

- GUI script output display was previously blank before Patch H. Current manual GUI testing should still verify that script output appears after **Refresh Status**, **Run Performance ON**, **Run Performance OFF**, and **Emergency Restore**.
- GUI sudo/admin handling may still need improvement. Some script actions can require administrator authorization, and the GUI may not yet provide the final intended authorization flow.

## Feature Gaps

- App Priority mutation is intentionally disabled. The current App Priority support is read-only monitoring only, because PIDs are unstable and can be reused, process identity can become stale, and priority changes need a safer authorization and restore model before they can be shipped. A future implementation should use a safer privileged-helper design rather than GUI-side renice calls.
- Fan control is not implemented yet.
- Most Advanced options are placeholder-only; only the existing Background Services pause preferences and Power Behavior sleep/display preferences are script-readable via `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`.
- Power Behavior placeholders for disk sleep, Power Nap, and keeping network awake are not implemented.

## Safety Boundaries

CatalinaPerformance should continue to avoid SIP changes, automatic cache deletion, permanent service disablement, launch daemon changes, undervolting, MSR changes, kext changes, and other irreversible or unsafe system modifications.
