# CatalinaPerformance

CatalinaPerformance is an early-stage macOS utility concept for older Intel Macs running macOS Catalina. The long-term goal is a simple, reversible **Performance Mode** toggle that temporarily reduces background activity and surfaces basic system health signals while the Mac is plugged in.

This repository is intentionally starting small. The first patches document the product goals, safety rules, planned features, and testing checklist before any system-changing code is added.

## Target Platform

- macOS Catalina 10.15
- Older Intel-based Macs
- User-controlled, reversible performance adjustments

## Core Concept

The app will eventually provide one main switch:

- **Performance Mode ON**: apply temporary, reversible settings intended to reduce background work and keep the Mac awake while on AC power.
- **Performance Mode OFF**: restore every setting changed by the app to its previous state.

Planned status indicators include:

- CPU temperature
- Fan speed
- RAM pressure
- Swap usage
- Disk space
- Whether sleep, Time Machine, Spotlight indexing, and thermal behavior adjustments are active

## Non-Goals for Early Patches

This repository now includes a minimal local macOS GUI shell. It does **not** implement a privileged helper, fan control, broad automatic Advanced system changes, launch daemon toggles, cache cleaning, undervolting, MSR changes, kext changes, SIP changes, or irreversible system tweaks. Future behavior should be built in small, reviewable patches after the safety model is documented.

## Safety Principles

CatalinaPerformance must be conservative by default:

- Keep all changes reversible.
- Every system tweak must have a matching restore path.
- Do not modify System Integrity Protection (SIP).
- Do not delete caches automatically.
- Do not disable services permanently.
- Prefer temporary sessions and explicit user consent over persistent changes.

See [docs/SAFETY_RULES.md](docs/SAFETY_RULES.md) for the detailed safety contract. See [docs/GUI_TESTING.md](docs/GUI_TESTING.md) for the current manual GUI test flow and [docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) for current limitations.

## Repository Layout

```text
.
├── README.md
├── AGENTS.md
├── docs/
│   ├── APP_CONCEPT.md
│   ├── FEATURE_PLAN.md
│   ├── GUI_TESTING.md
│   ├── KNOWN_ISSUES.md
│   ├── SAFETY_RULES.md
│   └── TESTING_CHECKLIST.md
├── app/
│   └── CatalinaPerformance/
│       ├── Package.swift
│       └── Sources/CatalinaPerformance/main.swift
└── scripts/
    ├── build_gui.sh
    ├── package_app.sh
    ├── emergency_restore.sh
    ├── memory_storage_report.sh
    ├── performance_off.sh
    ├── performance_on.sh
    ├── run_gui.sh
    ├── status_report.sh
    └── test_performance_cycle.sh
```

## Current Status

Initial documentation, safe script scaffolding, a minimal local GUI shell, and a local development `.app` packaging helper are present. Privileged helper behavior is not implemented yet.

## Local GUI Development

A minimal macOS GUI shell now lives in `app/CatalinaPerformance`. It is a Swift Package Manager AppKit executable targeting macOS Catalina 10.15 and older Intel Macs.

The GUI is intentionally thin:

- It displays the CatalinaPerformance app name, a Performance Mode ON/OFF switch, a small detected-state label, a success/failure status area, script output, and buttons for status refresh, Performance ON, Performance OFF, Emergency Restore, and Advanced.
- The Advanced window is now a planning/configuration UI organized into Background Services, Power Behavior, App Priority, Memory / Storage, Thermal / Fan, Experimental, and Emergency / Restore sections.
- Most Advanced controls are disabled placeholders clearly labeled `Not implemented yet`; the selectable Background Services, Power Behavior, and read-only Memory / Storage checkboxes write script-readable preferences to `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env`. `performance_on.sh` reads only the system-changing Background Services and Power Behavior preferences the next time Performance Mode is turned ON; the Memory / Storage preferences control only the manual read-only report. Missing or invalid preferences default to enabled for current-behavior compatibility.
- The Power Behavior section can configure the existing `pmset` behavior: **Prevent plugged-in system sleep while Performance Mode is ON** and **Prevent display sleep while Performance Mode is ON** both default to enabled. If either option is disabled, `performance_on.sh` still records the current `pmset` state but skips that specific `pmset -c` change and logs the skip; `performance_off.sh` restores only the selected actions that were recorded.
- Power Behavior placeholders for preventing disk sleep, disabling Power Nap, and keeping network awake remain visibly disabled and labeled `Not implemented yet`.
- The Memory / Storage section provides enabled-by-default read-only options for showing swap usage warnings, low disk space warnings, a memory pressure summary, and top memory-heavy processes. The **Run Memory / Storage Check** button calls `scripts/memory_storage_report.sh`, prints results in the main output area, uses no sudo, and does not delete files, clear caches, tune memory, or change settings.
- Memory / Storage warning thresholds are intentionally conservative and documented in the GUI and script output: swap usage above 1024 MB, disk free space below 10% or below 10 GB, and memory pressure output containing warn/critical states. Top disk-heavy folder scanning remains a disabled placeholder for a future optional read-only manual scan.
- Cache cleanup tools, browser cache cleanup, and automatic cleanup remain disabled and labeled **Not implemented yet — future manual-only feature** or discouraged; CatalinaPerformance does not perform automatic cleanup.
- It calls the existing scripts in `scripts/` instead of duplicating system-changing logic.
- It detects Performance Mode by checking `.catalina_performance_state/performance_mode_on`, then disables Performance ON while the marker exists and disables Performance OFF while the marker is absent. Emergency Restore remains available.
- It prints the exact `/bin/sh ...` command for each script, captures stdout and stderr in the scrollable output area, auto-scrolls after each run, and updates the status label with success or failure.
- It does not implement fan control, cache cleaning, SIP changes, launch daemon toggles, undervolting, MSR changes, kext loading, or experimental features.
- It shows warning confirmations before running Performance ON or Emergency Restore.

### Building the GUI

Use the local build helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/build_gui.sh
```

The helper only verifies the local developer tools and runs `swift build` in `app/CatalinaPerformance`; it does not change system settings or apply Performance Mode. It checks that an Xcode developer directory is selected, that `xcrun` can locate `xctest`, and that `swift` is available before building the package.

### Running the GUI from Terminal

Use the local run helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/run_gui.sh
```

The helper sets `CATALINA_PERFORMANCE_SCRIPTS_DIR` to this checkout's `scripts/` directory, prints the exact command it is about to run, then launches the Swift package with `swift run CatalinaPerformance`. The GUI still requires clear user intent before running any Performance Mode script.

You can also run the package manually from a macOS Catalina development machine with Xcode installed:

```sh
cd app/CatalinaPerformance
CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
```

### Packaging the Local `.app`

Use the local packaging helper from anywhere inside or outside the repository:

```sh
/path/to/Catilinaperformance-/scripts/package_app.sh
```

The packaging helper verifies that full Xcode is selected with `xcode-select`, confirms `xcrun` can find `xctest`, confirms `swift` is available, checks that the required GUI and performance scripts exist, runs `swift build`, then creates a local app bundle at:

```text
build/CatalinaPerformance.app
```

The generated bundle contains a simple `Info.plist`, the built Swift GUI executable, and a local launcher in `Contents/MacOS/`. The launcher preserves `CATALINA_PERFORMANCE_SCRIPTS_DIR` if it is already set; otherwise, it sets that environment variable to this checkout's `scripts/` directory so the GUI can find `status_report.sh`, `performance_on.sh`, `performance_off.sh`, and `emergency_restore.sh`.

### Launching the Packaged `.app`

After packaging, launch the app from Terminal with:

```sh
open /path/to/Catilinaperformance-/build/CatalinaPerformance.app
```

You may also double-click `build/CatalinaPerformance.app` in Finder on the development Mac. The packaged app uses the same GUI and scripts as `scripts/run_gui.sh`; it does not install anything into `/Applications`, does not add a privileged helper, does not add code signing or notarization, and does not change performance behavior.

### Current `.app` Limitations

The packaged `.app` is for local development only:

- It is unsigned and not notarized.
- It is not installed into `/Applications` automatically.
- The repository checkout must remain available because the app launcher points the GUI at the repo's `scripts/` directory.
- If the repository is moved after packaging, re-run `scripts/package_app.sh` so the generated launcher records the new scripts path.
- Advanced options are limited to configuring whether the existing Spotlight pause, Time Machine pause, plugged-in system sleep prevention, and display sleep prevention steps run, manual read-only Memory / Storage reporting, and one explicitly selected App Priority process boost with saved restore state. Most other controls are disabled placeholders, and no broad automatic system-changing behavior has been added. There is no fan control, cache cleaning, browser cleanup, automatic cleanup, launch daemon control, privileged helper, SIP modification, undervolting, MSR access, kext loading, or experimental CPU feature control.

### Xcode 12.4 and Catalina Notes

CatalinaPerformance targets macOS Catalina 10.15 and uses Swift Package Manager with AppKit. For the intended Catalina development environment, install Xcode 12.4 and open it at least once so macOS can finish installing required components. If multiple Xcode versions or only the command line tools are installed, select the full Xcode developer directory before building:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The helper scripts do not run `sudo`, do not change the selected developer directory, and do not alter SIP, caches, launch daemons, fan controls, or other system performance settings.

### xctest Troubleshooting

If `scripts/build_gui.sh` reports that `xcrun` cannot find `xctest`, the selected developer tools are usually incomplete or point at the command line tools instead of full Xcode. Check the selected path with:

```sh
xcode-select -p
xcrun -f xctest
```

On Catalina, resolve this by installing or repairing Xcode 12.4, opening Xcode once to complete setup, and selecting `/Applications/Xcode.app/Contents/Developer` with `xcode-select`. Re-run `scripts/build_gui.sh` after `xcrun -f xctest` prints a valid path.


### GUI Test Instructions

See [docs/GUI_TESTING.md](docs/GUI_TESTING.md) for the current manual GUI test flow. Use a macOS development machine for GUI behavior because the AppKit executable does not launch on non-macOS systems. To test the output and state handling safely during development:

1. Start from the package directory and point the GUI at the repository scripts if needed:

   ```sh
   cd app/CatalinaPerformance
   CATALINA_PERFORMANCE_SCRIPTS_DIR=/path/to/Catilinaperformance-/scripts swift run CatalinaPerformance
   ```

2. Click **Refresh Status** and confirm the output box shows the exact `/bin/sh .../status_report.sh` command followed by script stdout/stderr and an exit-status line.
3. With `.catalina_performance_state/performance_mode_on` absent, confirm the state label says **Performance Mode appears OFF**, **Run Performance OFF** is disabled, **Run Performance ON** is enabled, and **Emergency Restore** remains enabled.
4. Create or preserve the marker file only through the reviewed scripts when possible. After running **Run Performance ON**, confirm the GUI refreshes the switch and state label from `.catalina_performance_state/performance_mode_on`, disables **Run Performance ON**, and keeps output scrolled to the latest exit-status line.
5. After running **Run Performance OFF** or **Emergency Restore**, confirm the marker is removed, the switch and label show OFF, **Run Performance OFF** is disabled, and **Emergency Restore** remains enabled.
6. Open **Advanced** and confirm the panel shows planning sections for Background Services, Power Behavior, App Priority, Memory / Storage, Thermal / Fan, Experimental, and Emergency / Restore. Confirm disabled controls are labeled **Not implemented yet**. Toggle the selectable Background Services, Power Behavior, and Memory / Storage preferences and confirm they save to `~/Library/Application Support/CatalinaPerformance/advanced_preferences.env` without running system-changing scripts immediately; only the Background Services and Power Behavior preferences affect the next Performance ON run.
7. In **Advanced > Memory / Storage**, click **Run Memory / Storage Check** and confirm the main output area shows `scripts/memory_storage_report.sh` output for the enabled read-only checks. Confirm cache cleanup, browser cache cleanup, automatic cleanup, and top disk-heavy folder scanning remain disabled placeholders and that no files are deleted.
8. Repeat an ON/OFF cycle and verify each run reports a clear success or failure in the status label without adding fan control, cache cleaning, SIP changes, launch daemon controls, privileged helpers, or broad automatic Advanced behavior.

Future packaged `.app` work should keep the same app/script boundary: the GUI may collect user intent and display output, while reversible system behavior and restore paths remain in reviewed scripts.

## Advanced App Priority

The Advanced App Priority section is functional but intentionally narrow. It lists running user-owned processes with PID, process name, nice value, CPU %, memory %, and owner, then lets the user select exactly one target process. When the user explicitly chooses **Apply Priority Boost Now**, CatalinaPerformance calls `scripts/app_priority_apply.sh` as the logged-in GUI user, validates the selected process owner, saves the selected process's original nice value and identity under `.catalina_performance_state/app_priority/`, logs the action, and applies a conservative nice value of `-5` by default. Administrator authorization is requested only for the narrow priority-changing `renice` command when macOS requires it.

App Priority does **not** boost every app, lower background apps, auto-detect games/emulators/browsers, boost process trees, set CPU affinity, modify SIP, install helpers, load kexts, change fan control, clean caches, unload launch daemons, undervolt, or use MSR/experimental CPU controls. Only one selected process is supported for now so state capture, user intent, and restore behavior stay easy to audit.

Restoration is handled by `scripts/app_priority_restore.sh`, which reads only CatalinaPerformance's saved app-priority state, restores only entries marked `APPLY_STATUS=applied`, verifies process identity rather than trusting PID alone before restoring (owner, command, full command when available, and process start time when available), skips stale, closed, pending, failed, or cancelled entries, and prints a summary of attempted, successful, skipped, and failed restores. If apply finds an old state file for a reused PID, it archives the stale state before writing fresh identity for the current process so the new boost has a valid restore path. `scripts/performance_off.sh` also attempts this restore automatically when app-priority state exists, but continues with the existing pmset, Time Machine, and Spotlight restore flow if app-priority restore reports a problem.

System and protected processes are blocked by default. The apply script refuses PID 0, PID 1, root/admin-owned processes unless explicitly allowed, and critical services such as `launchd`, `kernel_task`, `WindowServer`, `loginwindow`, Spotlight metadata services, backup services, `securityd`, `coreaudiod`, `configd`, Bluetooth, and Open Directory services.

Manual commands:

```sh
scripts/app_priority_report.sh
scripts/app_priority_apply.sh --pid 12345 --yes
scripts/app_priority_restore.sh --dry-run --yes
scripts/app_priority_restore.sh --yes
```
