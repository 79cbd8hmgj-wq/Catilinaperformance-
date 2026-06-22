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
- Most Advanced options are still placeholder-only; App Priority is limited to one explicitly selected process.
- App Priority boosting may not noticeably improve every app because scheduler behavior, bottlenecks, thermal limits, I/O, and GPU work can dominate performance.
- Some priority changes may require administrator authorization, especially when lowering a nice value for a stronger priority boost.
- Protected or system processes are intentionally blocked by App Priority scripts to avoid destabilizing macOS.
- Closed processes cannot have their priority restored because the original PID no longer exists.
- Process IDs change after relaunch, so saved selections must not be blindly reused for automatic boosting.

## Safety Boundaries

CatalinaPerformance should continue to avoid SIP changes, automatic cache deletion, permanent service disablement, launch daemon changes, undervolting, MSR changes, kext changes, and other irreversible or unsafe system modifications.
