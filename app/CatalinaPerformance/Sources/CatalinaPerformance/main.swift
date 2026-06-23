import Foundation

#if canImport(AppKit)
import AppKit

/// CatalinaPerformance's GUI is intentionally a thin shell around the scripts in
/// `scripts/`. System-changing behavior belongs in those reviewed scripts so the
/// app does not duplicate restore logic or drift from the documented safety model.
final class ScriptRunner {
    private let fileManager = FileManager.default
    private let explicitScriptsDirectory: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let configured = environment["CATALINA_PERFORMANCE_SCRIPTS_DIR"], !configured.isEmpty {
            explicitScriptsDirectory = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            explicitScriptsDirectory = nil
        }
    }

    func scriptCommand(for script: ScriptKind) -> String {
        let scriptURL = resolveScript(named: script.fileName)
        return (["/bin/sh", scriptURL.path] + script.arguments).joined(separator: " ")
    }

    func run(_ script: ScriptKind, completion: @escaping (ScriptResult) -> Void) {
        let scriptURL = resolveScript(named: script.fileName)
        let launchCommand = scriptCommand(for: script)
        guard scriptExists(at: scriptURL) else {
            completion(ScriptResult(command: launchCommand, output: missingScriptMessage(scriptURL), exitStatus: nil, timedOut: false, cancelled: false))
            return
        }

        if script.requiresAdministratorPrivileges {
            runWithAdministratorPrivileges(script, scriptURL: scriptURL, launchCommand: launchCommand, completion: completion)
        } else {
            runDirect(script, scriptURL: scriptURL, launchCommand: launchCommand, completion: completion)
        }
    }

    private func runDirect(_ script: ScriptKind, scriptURL: URL, launchCommand: String, completion: @escaping (ScriptResult) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path] + script.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CATALINA_PERFORMANCE_PREFERENCES_FILE"] = AdvancedPreferences.configFileURL.path
        process.environment = environment
        finish(process, script: script, launchCommand: launchCommand, timeout: 60, completion: completion)
    }

    private func runWithAdministratorPrivileges(_ script: ScriptKind, scriptURL: URL, launchCommand: String, completion: @escaping (ScriptResult) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", administratorAppleScript(for: scriptURL, arguments: script.arguments)]
        finish(process, script: script, launchCommand: launchCommand, timeout: 300, completion: completion)
    }

    private func finish(_ process: Process, script: ScriptKind, launchCommand: String, timeout: TimeInterval, completion: @escaping (ScriptResult) -> Void) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var didFinish = false

        func complete(_ result: ScriptResult) {
            DispatchQueue.main.async {
                if didFinish { return }
                didFinish = true
                completion(result)
            }
        }

        do {
            try process.run()
        } catch {
            completion(ScriptResult(command: launchCommand, output: "Failed to start \(script.fileName): \(error.localizedDescription)", exitStatus: nil, timedOut: false, cancelled: false))
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                process.terminate()
                complete(ScriptResult(command: launchCommand, output: "Timed out after \(Int(timeout)) seconds. The script was stopped so the UI would not remain stuck.", exitStatus: nil, timedOut: true, cancelled: false))
            }
        }

        process.terminationHandler = { process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let cancelled = script.requiresAdministratorPrivileges && process.terminationStatus != 0 && output.localizedCaseInsensitiveContains("User canceled")
            complete(ScriptResult(command: launchCommand, output: cancelled ? "Cancelled by user" : output, exitStatus: process.terminationStatus, timedOut: false, cancelled: cancelled))
        }
    }

    private func scriptExists(at scriptURL: URL) -> Bool {
        fileManager.isExecutableFile(atPath: scriptURL.path) || fileManager.fileExists(atPath: scriptURL.path)
    }

    private func missingScriptMessage(_ scriptURL: URL) -> String {
        "Script not found: \(scriptURL.path)\nSet CATALINA_PERFORMANCE_SCRIPTS_DIR to the repository scripts directory during development."
    }

    private func administratorAppleScript(for scriptURL: URL, arguments: [String]) -> String {
        let environmentPrefix = "CATALINA_PERFORMANCE_PREFERENCES_FILE=" + shellQuote(AdvancedPreferences.configFileURL.path)
        let command = ([environmentPrefix, "/bin/sh", scriptURL.path] + arguments).map { value in
            value == environmentPrefix ? value : shellQuote(value)
        }.joined(separator: " ")
        return "do shell script \(appleScriptString(command)) with administrator privileges"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func performanceModeIsOn() -> Bool {
        fileManager.fileExists(atPath: performanceModeMarkerURL.path)
    }

    private var performanceModeMarkerURL: URL {
        repositoryRootURL.appendingPathComponent(".catalina_performance_state", isDirectory: true)
            .appendingPathComponent("performance_mode_on")
    }

    var repositoryRootURL: URL {
        resolveScript(named: ScriptKind.status.fileName)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private func resolveScript(named fileName: String) -> URL {
        if let explicitScriptsDirectory = explicitScriptsDirectory {
            return explicitScriptsDirectory.appendingPathComponent(fileName)
        }

        // Development fallback: resolve from the Swift package directory back to
        // the repository root, then into scripts/. Bundled app packaging can set
        // CATALINA_PERFORMANCE_SCRIPTS_DIR or add a future resource lookup here.
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let packageRelative = currentDirectory
            .appendingPathComponent("../../scripts", isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: packageRelative.path) {
            return packageRelative
        }

        return currentDirectory
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}


struct AdvancedPreferences {
    static let pauseSpotlightKey = "advanced.pauseSpotlightWhileOn"
    static let pauseTimeMachineKey = "advanced.pauseTimeMachineWhileOn"
    static let preventSystemSleepKey = "advanced.preventPluggedInSystemSleepWhileOn"
    static let preventDisplaySleepKey = "advanced.preventDisplaySleepWhileOn"
    static let showSwapUsageWarningKey = "advanced.showSwapUsageWarning"
    static let showLowDiskSpaceWarningKey = "advanced.showLowDiskSpaceWarning"
    static let showMemoryPressureSummaryKey = "advanced.showMemoryPressureSummary"
    static let showTopMemoryProcessesKey = "advanced.showTopMemoryProcesses"
    static let configFileName = "advanced_preferences.env"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pauseSpotlightKey: true,
            pauseTimeMachineKey: true,
            preventSystemSleepKey: true,
            preventDisplaySleepKey: true,
            showSwapUsageWarningKey: true,
            showLowDiskSpaceWarningKey: true,
            showMemoryPressureSummaryKey: true,
            showTopMemoryProcessesKey: true
        ])
    }

    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CatalinaPerformance", isDirectory: true)
    }

    static var configFileURL: URL {
        configDirectoryURL.appendingPathComponent(configFileName)
    }

    @discardableResult
    static func writeScriptConfig(defaults: UserDefaults = .standard) -> Result<URL, Error> {
        let spotlight = defaults.bool(forKey: pauseSpotlightKey) ? "1" : "0"
        let timeMachine = defaults.bool(forKey: pauseTimeMachineKey) ? "1" : "0"
        let systemSleep = defaults.bool(forKey: preventSystemSleepKey) ? "1" : "0"
        let displaySleep = defaults.bool(forKey: preventDisplaySleepKey) ? "1" : "0"
        let swapWarning = defaults.bool(forKey: showSwapUsageWarningKey) ? "1" : "0"
        let diskWarning = defaults.bool(forKey: showLowDiskSpaceWarningKey) ? "1" : "0"
        let memoryPressure = defaults.bool(forKey: showMemoryPressureSummaryKey) ? "1" : "0"
        let topMemoryProcesses = defaults.bool(forKey: showTopMemoryProcessesKey) ? "1" : "0"
        let contents = "# CatalinaPerformance Advanced preferences.\n# Values are 1 for enabled and 0 for disabled. Missing or invalid values default to enabled in scripts.\nPAUSE_SPOTLIGHT_WHILE_ON=\(spotlight)\nPAUSE_TIME_MACHINE_WHILE_ON=\(timeMachine)\nPREVENT_SYSTEM_SLEEP_WHILE_ON=\(systemSleep)\nPREVENT_DISPLAY_SLEEP_WHILE_ON=\(displaySleep)\nSHOW_SWAP_USAGE_WARNING=\(swapWarning)\nSHOW_LOW_DISK_SPACE_WARNING=\(diskWarning)\nSHOW_MEMORY_PRESSURE_SUMMARY=\(memoryPressure)\nSHOW_TOP_MEMORY_PROCESSES=\(topMemoryProcesses)\n"

        do {
            try FileManager.default.createDirectory(at: configDirectoryURL, withIntermediateDirectories: true)
            try contents.write(to: configFileURL, atomically: true, encoding: .utf8)
            return .success(configFileURL)
        } catch {
            NSLog("Unable to write CatalinaPerformance script preferences: \(error.localizedDescription)")
            return .failure(error)
        }
    }
}

struct ScriptResult {
    let command: String
    let output: String
    let exitStatus: Int32?
    let timedOut: Bool
    let cancelled: Bool

    var succeeded: Bool {
        exitStatus == 0 && !timedOut && !cancelled
    }
}

enum ScriptKind {
    case status
    case performanceOn
    case performanceOff
    case emergencyRestore
    case memoryStorageReport
    case appPriorityReport
    case thermalFanReport

    var fileName: String {
        switch self {
        case .status: return "status_report.sh"
        case .performanceOn: return "performance_on.sh"
        case .performanceOff: return "performance_off.sh"
        case .emergencyRestore: return "emergency_restore.sh"
        case .memoryStorageReport: return "memory_storage_report.sh"
        case .appPriorityReport: return "app_priority_report.sh"
        case .thermalFanReport: return "thermal_fan_report.sh"
        }
    }

    var arguments: [String] {
        switch self {
        case .performanceOn, .emergencyRestore:
            // The GUI provides the explicit warning/intent gate before invoking
            // these scripts, then passes --yes so script output can be captured
            // in the app instead of blocking on terminal input.
            return ["--yes"]
        case .status, .performanceOff, .memoryStorageReport, .appPriorityReport, .thermalFanReport:
            return []
        }
    }

    var requiresAdministratorPrivileges: Bool {
        switch self {
        case .performanceOn, .performanceOff, .emergencyRestore:
            return true
        case .status, .memoryStorageReport, .appPriorityReport, .thermalFanReport:
            return false
        }
    }
}

final class MainWindowController: NSWindowController {
    let runner = ScriptRunner()
    private let statusLabel = NSTextField(labelWithString: "Status: Not refreshed yet.")
    private let modeStateLabel = NSTextField(labelWithString: "Performance Mode appears OFF.")
    private let modeSwitch = NSSwitch()
    private let outputTextView = NSTextView(frame: .zero)
    private let onButton = NSButton(title: "Run Performance ON", target: nil, action: nil)
    private let offButton = NSButton(title: "Run Performance OFF", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Emergency Restore", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Status", target: nil, action: nil)
    private let advancedButton = NSButton(title: "Advanced", target: nil, action: nil)
    private var activeScriptCount = 0
    private var advancedWindowController: AdvancedWindowController?

    private var isScriptRunning: Bool {
        activeScriptCount > 0
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance"
        self.init(window: window)
        buildInterface()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "CatalinaPerformance")
        title.font = NSFont.boldSystemFont(ofSize: 28)

        let switchLabel = NSTextField(labelWithString: "Performance Mode ON/OFF")
        let switchRow = NSStackView(views: [switchLabel, modeSwitch])
        switchRow.orientation = .horizontal
        switchRow.spacing = 12
        switchRow.alignment = .centerY

        refreshButton.target = self
        refreshButton.action = #selector(refreshStatus)
        onButton.target = self
        onButton.action = #selector(runPerformanceOn)
        offButton.target = self
        offButton.action = #selector(runPerformanceOff)
        restoreButton.target = self
        restoreButton.action = #selector(runEmergencyRestore)
        advancedButton.target = self
        advancedButton.action = #selector(showAdvanced)
        let buttons = NSStackView(views: [refreshButton, onButton, offButton, restoreButton, advancedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillProportionally

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.textColor = .textColor
        outputTextView.backgroundColor = .textBackgroundColor
        outputTextView.insertionPointColor = .textColor
        outputTextView.minSize = NSSize(width: 0, height: 0)
        outputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.isVerticallyResizable = true
        outputTextView.isHorizontallyResizable = false
        outputTextView.autoresizingMask = [.width]
        outputTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        outputTextView.textContainer?.widthTracksTextView = true
        outputTextView.string = "Script output will appear here.\n"
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = outputTextView

        let layout = NSStackView(views: [title, switchRow, modeStateLabel, statusLabel, buttons, scrollView])
        layout.orientation = .vertical
        layout.spacing = 14
        layout.alignment = .leading
        layout.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(layout)

        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            scrollView.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])

        updateModeControls()
    }

    @objc private func refreshStatus() {
        run(.status, status: "Refreshing status...")
    }

    @objc private func runPerformanceOn() {
        confirm(
            title: "Turn Performance Mode ON?",
            message: "This will run the reviewed performance_on.sh script using the macOS administrator authorization prompt. It records prior state before changes and does not implement fan control, cache deletion, SIP changes, kexts, undervolting, or experimental features."
        ) { [weak self] in
            self?.run(.performanceOn, status: "Performance Mode ON requested...")
        }
    }

    @objc private func runPerformanceOff() {
        run(.performanceOff, status: "Performance Mode OFF requested...")
    }

    @objc private func runEmergencyRestore() {
        confirm(
            title: "Run Emergency Restore?",
            message: "Emergency Restore is a fallback path for recoverable state. It calls emergency_restore.sh and will not delete caches, modify SIP, touch fan control, unload arbitrary services, install kexts, undervolt, or use experimental CPU/MSR changes."
        ) { [weak self] in
            self?.run(.emergencyRestore, status: "Emergency Restore requested...")
        }
    }

    @objc private func showAdvanced() {
        if advancedWindowController == nil {
            advancedWindowController = AdvancedWindowController(
                onRunAppPriorityReport: { [weak self] in
                    self?.run(.appPriorityReport, status: "Running App Priority report...")
                },
                onRunMemoryStorageCheck: { [weak self] in
                    self?.run(.memoryStorageReport, status: "Running Memory / Storage check...")
                },
                onRunThermalFanCheck: { [weak self] in
                    self?.run(.thermalFanReport, status: "Running Thermal / Fan check...")
                },
                onPreferenceWriteFailure: { [weak self] message in
                    self?.showPreferenceWriteFailure(message)
                }
            )
        }
        advancedWindowController?.setScriptActionsEnabled(!isScriptRunning)
        advancedWindowController?.showWindow(nil)
        advancedWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func showPreferenceWriteFailure(_ message: String) {
        statusLabel.stringValue = "Status: Advanced preferences could not be saved."
        appendOutput("\n[Advanced preferences error] \(message)\n")
    }

    private func confirm(title: String, message: String, then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func run(_ script: ScriptKind, status: String) {
        guard !isScriptRunning else {
            statusLabel.stringValue = "Status: Another CatalinaPerformance action is already running."
            appendOutput("\nAnother CatalinaPerformance action is already running. Wait for the active script to finish before starting \(script.fileName).\n")
            outputTextView.scrollToEndOfDocument(nil)
            return
        }

        activeScriptCount += 1
        statusLabel.stringValue = "Status: \(status)"
        updateRunControls()
        appendOutput("\n$ \(runner.scriptCommand(for: script))\n")
        runner.run(script) { [weak self] result in
            guard let self = self else { return }
            let output = result.output.isEmpty ? "(No output.)\n" : result.output
            self.appendOutput(output.hasSuffix("\n") ? output : output + "\n")

            if let exitStatus = result.exitStatus {
                self.appendOutput("[\(script.fileName) exited with status \(exitStatus)]\n")
                if result.cancelled {
                    self.statusLabel.stringValue = "Status: Cancelled by user."
                } else {
                    self.statusLabel.stringValue = result.succeeded
                        ? "Status: Success running \(script.fileName)."
                        : "Status: Failed running \(script.fileName) (exit \(exitStatus))."
                }
            } else {
                self.appendOutput(result.timedOut ? "[\(script.fileName) timed out]\n" : "[\(script.fileName) did not start]\n")
                self.statusLabel.stringValue = result.timedOut ? "Status: Timed out running \(script.fileName)." : "Status: Failed running \(script.fileName) before exit."
            }

            self.activeScriptCount = max(0, self.activeScriptCount - 1)
            self.updateRunControls()
            self.outputTextView.scrollToEndOfDocument(nil)
        }
    }

    private func updateModeControls() {
        updateRunControls()
    }

    private func updateRunControls() {
        let isOn = runner.performanceModeIsOn()
        modeSwitch.state = isOn ? .on : .off
        modeStateLabel.stringValue = "Performance Mode appears \(isOn ? "ON" : "OFF")."

        let canStartScript = !isScriptRunning
        refreshButton.isEnabled = canStartScript
        onButton.isEnabled = canStartScript && !isOn
        offButton.isEnabled = canStartScript && isOn
        restoreButton.isEnabled = canStartScript
        advancedButton.isEnabled = true
        advancedWindowController?.setScriptActionsEnabled(canStartScript)
    }

    private func appendOutput(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: outputTextView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        outputTextView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        outputTextView.needsDisplay = true
        outputTextView.scrollRangeToVisible(NSRange(location: outputTextView.string.count, length: 0))
    }
}


final class AdvancedWindowController: NSWindowController {
    private let preferences = UserDefaults.standard
    private var memoryStorageButton: NSButton?
    private var appPriorityButton: NSButton?
    private var thermalFanButton: NSButton?
    private var onRunAppPriorityReport: (() -> Void)?
    private var onRunMemoryStorageCheck: (() -> Void)?
    private var onRunThermalFanCheck: (() -> Void)?
    private var onPreferenceWriteFailure: ((String) -> Void)?

    convenience init(onRunAppPriorityReport: (() -> Void)? = nil, onRunMemoryStorageCheck: (() -> Void)? = nil, onRunThermalFanCheck: (() -> Void)? = nil, onPreferenceWriteFailure: ((String) -> Void)? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance Advanced"
        self.init(window: window)
        self.onRunAppPriorityReport = onRunAppPriorityReport
        self.onRunMemoryStorageCheck = onRunMemoryStorageCheck
        self.onRunThermalFanCheck = onRunThermalFanCheck
        self.onPreferenceWriteFailure = onPreferenceWriteFailure
        AdvancedPreferences.registerDefaults(in: preferences)
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
        buildInterface()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Advanced")
        title.font = NSFont.boldSystemFont(ofSize: 24)
        let description = wrappedLabel("Configure Advanced preferences. Background-service and power-management changes apply only when Performance Mode is explicitly turned ON. App Priority, Memory / Storage, and Thermal / Fan checks are read-only status reports and do not renice processes, delete files, clear caches, tune memory, control fans, write SMC values, or change system settings.")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(description)
        stack.addArrangedSubview(section("Background Services", controls: [
            advancedCheckbox("Pause Spotlight indexing while Performance Mode is ON", key: AdvancedPreferences.pauseSpotlightKey),
            advancedCheckbox("Pause Time Machine automatic backups while Performance Mode is ON", key: AdvancedPreferences.pauseTimeMachineKey),
            disabledCheckbox("Pause software update checks — Not implemented yet"),
            disabledCheckbox("Pause selected launch agents — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Power Behavior", controls: [
            advancedCheckbox("Prevent plugged-in system sleep while Performance Mode is ON", key: AdvancedPreferences.preventSystemSleepKey),
            advancedCheckbox("Prevent display sleep while Performance Mode is ON", key: AdvancedPreferences.preventDisplaySleepKey),
            disabledCheckbox("Prevent disk sleep — Not implemented yet"),
            disabledCheckbox("Disable Power Nap — Not implemented yet"),
            disabledCheckbox("Keep network awake — Not implemented yet")
        ]))
        let appPriorityButton = NSButton(title: "Run App Priority Report", target: self, action: #selector(runAppPriorityReport))
        self.appPriorityButton = appPriorityButton
        stack.addArrangedSubview(section("App Priority", controls: [
            wrappedLabel("Read-only monitoring only. The report lists current user processes with PID, owner, nice value, CPU %, memory %, and command. It requires no sudo and never changes process priority."),
            appPriorityButton,
            disabledCheckbox("Apply Priority Boost Now — Not implemented yet — disabled for safety"),
            disabledCheckbox("Restore Priority — Not implemented yet — disabled for safety"),
            disabledCheckbox("Enable selected app priority boost while Performance Mode is ON — Not implemented yet — disabled for safety")
        ]))
        let memoryStorageButton = NSButton(title: "Run Memory / Storage Check", target: self, action: #selector(runMemoryStorageCheck))
        self.memoryStorageButton = memoryStorageButton
        stack.addArrangedSubview(section("Memory / Storage", controls: [
            wrappedLabel("Read-only warnings use conservative thresholds: swap above 1024 MB, disk free space below 10% or 10 GB, and macOS memory_pressure warn/critical output. These checks do not require sudo and do not modify the system."),
            advancedCheckbox("Show swap usage warning", key: AdvancedPreferences.showSwapUsageWarningKey),
            advancedCheckbox("Show low disk space warning", key: AdvancedPreferences.showLowDiskSpaceWarningKey),
            advancedCheckbox("Show memory pressure summary", key: AdvancedPreferences.showMemoryPressureSummaryKey),
            advancedCheckbox("Show top memory-heavy processes", key: AdvancedPreferences.showTopMemoryProcessesKey),
            memoryStorageButton,
            disabledCheckbox("Show top disk-heavy folders — Optional read-only scan not implemented yet"),
            disabledCheckbox("Cache cleanup tools — Not implemented yet — future manual-only feature"),
            disabledCheckbox("Browser cache cleanup — Not implemented yet — future manual-only feature"),
            disabledCheckbox("Automatic cleanup — Disabled and discouraged; not implemented")
        ]))
        let thermalFanButton = NSButton(title: "Run Thermal / Fan Check", target: self, action: #selector(runThermalFanCheck))
        self.thermalFanButton = thermalFanButton
        stack.addArrangedSubview(section("Thermal / Fan", controls: [
            wrappedLabel("Read-only monitoring only. The check reports thermal pressure/status when available, attempts to assess thermal constraints from safe built-in status output, and clearly warns when CPU temperature or fan RPM are unavailable without privileged or SMC access."),
            thermalFanButton,
            disabledCheckbox("Aggressive fan behavior — Not implemented yet"),
            disabledCheckbox("Max fans while Performance Mode is ON — Not implemented yet"),
            disabledCheckbox("Custom fan curve — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Experimental", controls: [
            disabledCheckbox("Turbo Boost detection — Not implemented yet"),
            disabledCheckbox("Turbo Boost control — Not implemented yet"),
            disabledCheckbox("MSR read access — Not implemented yet"),
            disabledCheckbox("Undervolting attempt — Not implemented yet"),
            disabledCheckbox("Legacy kext support — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Emergency / Restore", controls: [
            wrappedLabel("Emergency Restore remains available on the main screen and uses scripts/emergency_restore.sh. No additional restore behavior is controlled from this Advanced panel yet.")
        ]))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 16),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -32)
        ])
    }

    private func section(_ title: String, controls: [NSView]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        let stack = NSStackView(views: [titleLabel] + controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func advancedCheckbox(_ title: String, key: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: #selector(savePreference(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier(rawValue: key)
        checkbox.state = preferences.bool(forKey: key) ? .on : .off
        return checkbox
    }

    private func disabledCheckbox(_ title: String) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        checkbox.isEnabled = false
        checkbox.state = .off
        return checkbox
    }

    func setScriptActionsEnabled(_ enabled: Bool) {
        memoryStorageButton?.isEnabled = enabled
        appPriorityButton?.isEnabled = enabled
        thermalFanButton?.isEnabled = enabled
    }

    private func wrappedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func runAppPriorityReport() {
        onRunAppPriorityReport?()
    }

    @objc private func runMemoryStorageCheck() {
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
        onRunMemoryStorageCheck?()
    }

    @objc private func runThermalFanCheck() {
        onRunThermalFanCheck?()
    }

    @objc private func savePreference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        preferences.set(sender.state == .on, forKey: key)
        reportPreferenceWriteResult(AdvancedPreferences.writeScriptConfig(defaults: preferences))
    }

    private func reportPreferenceWriteResult(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            let message = "Unable to write Advanced preferences to \(AdvancedPreferences.configFileURL.path): \(error.localizedDescription)"
            onPreferenceWriteFailure?(message)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AdvancedPreferences.registerDefaults()
        let controller = MainWindowController()
        if case .failure(let error) = AdvancedPreferences.writeScriptConfig() {
            controller.showPreferenceWriteFailure("Unable to write Advanced preferences to \(AdvancedPreferences.configFileURL.path): \(error.localizedDescription)")
        }
        controller.showWindow(nil)
        mainWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
#else
print("CatalinaPerformance GUI requires macOS AppKit. Run this package on macOS Catalina or newer to launch the interface.")
#endif
