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
        let command = (["/bin/sh", scriptURL.path] + arguments).map(shellQuote).joined(separator: " ")
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
    static let configFileName = "advanced_background_services.conf"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pauseSpotlightKey: true,
            pauseTimeMachineKey: true
        ])
    }

    static func writeScriptConfig(repositoryRootURL: URL, defaults: UserDefaults = .standard) {
        let directory = repositoryRootURL.appendingPathComponent(".catalina_performance_preferences", isDirectory: true)
        let fileURL = directory.appendingPathComponent(configFileName)
        let spotlight = defaults.bool(forKey: pauseSpotlightKey) ? "1" : "0"
        let timeMachine = defaults.bool(forKey: pauseTimeMachineKey) ? "1" : "0"
        let contents = "# CatalinaPerformance Advanced Background Services preferences.\n# Values are 1 for enabled and 0 for disabled. Missing or invalid values default to enabled in scripts.\nPAUSE_SPOTLIGHT_WHILE_ON=\(spotlight)\nPAUSE_TIME_MACHINE_WHILE_ON=\(timeMachine)\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Unable to write CatalinaPerformance script preferences: \(error.localizedDescription)")
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

    var fileName: String {
        switch self {
        case .status: return "status_report.sh"
        case .performanceOn: return "performance_on.sh"
        case .performanceOff: return "performance_off.sh"
        case .emergencyRestore: return "emergency_restore.sh"
        }
    }

    var arguments: [String] {
        switch self {
        case .performanceOn, .emergencyRestore:
            // The GUI provides the explicit warning/intent gate before invoking
            // these scripts, then passes --yes so script output can be captured
            // in the app instead of blocking on terminal input.
            return ["--yes"]
        case .status, .performanceOff:
            return []
        }
    }

    var requiresAdministratorPrivileges: Bool {
        switch self {
        case .performanceOn, .performanceOff, .emergencyRestore:
            return true
        case .status:
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
    private let advancedButton = NSButton(title: "Advanced", target: nil, action: nil)
    private var advancedWindowController: AdvancedWindowController?

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

        let refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshStatus))
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
            advancedWindowController = AdvancedWindowController(repositoryRootURL: runner.repositoryRootURL)
        }
        advancedWindowController?.showWindow(nil)
        advancedWindowController?.window?.makeKeyAndOrderFront(nil)
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
        statusLabel.stringValue = "Status: \(status)"
        setRunButtonsEnabled(false)
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

            self.setRunButtonsEnabled(true)
            self.outputTextView.scrollToEndOfDocument(nil)
        }
    }

    private func updateModeControls() {
        let isOn = runner.performanceModeIsOn()
        modeSwitch.state = isOn ? .on : .off
        modeStateLabel.stringValue = "Performance Mode appears \(isOn ? "ON" : "OFF")."
        onButton.isEnabled = !isOn
        offButton.isEnabled = isOn
        restoreButton.isEnabled = true
    }

    private func setRunButtonsEnabled(_ enabled: Bool) {
        if enabled {
            updateModeControls()
        } else {
            onButton.isEnabled = false
            offButton.isEnabled = false
            restoreButton.isEnabled = false
        }
        advancedButton.isEnabled = true
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
    private var repositoryRootURL = URL(fileURLWithPath: ".", isDirectory: true)

    convenience init(repositoryRootURL: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CatalinaPerformance Advanced"
        self.init(window: window)
        self.repositoryRootURL = repositoryRootURL
        AdvancedPreferences.registerDefaults(in: preferences)
        AdvancedPreferences.writeScriptConfig(repositoryRootURL: repositoryRootURL, defaults: preferences)
        buildInterface()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Advanced")
        title.font = NSFont.boldSystemFont(ofSize: 24)
        let description = wrappedLabel("Configure which existing background-service pauses Performance Mode applies. Changes are saved locally and read by performance_on.sh the next time Performance Mode is turned ON.")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(description)
        stack.addArrangedSubview(section("Background Services", controls: [
            backgroundServiceCheckbox("Pause Spotlight indexing while Performance Mode is ON", key: AdvancedPreferences.pauseSpotlightKey),
            backgroundServiceCheckbox("Pause Time Machine automatic backups while Performance Mode is ON", key: AdvancedPreferences.pauseTimeMachineKey),
            disabledCheckbox("Pause software update checks — Not implemented yet"),
            disabledCheckbox("Pause selected launch agents — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Power Behavior", controls: [
            disabledCheckbox("Prevent plugged-in sleep while Performance Mode is ON — Not configurable yet"),
            disabledCheckbox("Prevent display sleep while Performance Mode is ON — Not configurable yet"),
            disabledCheckbox("Prevent disk sleep — Not implemented yet"),
            disabledCheckbox("Disable Power Nap — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("App Priority", controls: [
            disabledCheckbox("Boost selected foreground app — Not implemented yet"),
            disabledCheckbox("Lower background app priority — Not implemented yet")
        ]))
        stack.addArrangedSubview(section("Memory / Storage", controls: [
            disabledCheckbox("Show swap warning — Not implemented yet"),
            disabledCheckbox("Show low disk warning — Not implemented yet"),
            disabledCheckbox("Cache cleanup tools — Not implemented yet; future manual-only feature")
        ]))
        stack.addArrangedSubview(section("Thermal / Fan", controls: [
            disabledCheckbox("Show fan RPM — Not implemented yet"),
            disabledCheckbox("Show CPU temperature — Not implemented yet"),
            disabledCheckbox("Aggressive fan behavior — Not implemented yet"),
            disabledCheckbox("Max fans while Performance Mode is ON — Not implemented yet")
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

    private func backgroundServiceCheckbox(_ title: String, key: String) -> NSButton {
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

    private func wrappedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func savePreference(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        preferences.set(sender.state == .on, forKey: key)
        AdvancedPreferences.writeScriptConfig(repositoryRootURL: repositoryRootURL, defaults: preferences)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AdvancedPreferences.registerDefaults()
        let controller = MainWindowController()
        AdvancedPreferences.writeScriptConfig(repositoryRootURL: controller.runner.repositoryRootURL)
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
