import Foundation
import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio
import Security

// MARK: - Configuration
let tmpDir = "/tmp"

func findExecutable(_ name: String) -> String? {
    let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/Library/Python/3.14/bin",
        NSHomeDirectory() + "/Library/Python/3.13/bin",
        NSHomeDirectory() + "/Library/Python/3.12/bin",
        NSHomeDirectory() + "/Library/Python/3.11/bin"
    ]
    for dir in searchPaths {
        let path = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    // Try `which` as fallback
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            return result
        }
    } catch {}
    return nil
}

let whisperPath = findExecutable("whisper") ?? "/opt/homebrew/bin/whisper"
let pythonPath = findExecutable("python3") ?? "/opt/homebrew/bin/python3"
let systemPATH = [
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    NSHomeDirectory() + "/.local/bin"
].joined(separator: ":")

let availableModels = ["tiny.en", "base.en", "small.en", "medium.en", "turbo"]
let defaultModel = "base.en"
let whisperCacheDir = NSHomeDirectory() + "/.cache/whisper"
let modelExpectedSizes: [String: String] = [
    "tiny.en": "~75 MB",
    "base.en": "~140 MB",
    "small.en": "~465 MB",
    "medium.en": "~1.5 GB",
    "turbo": "~1.6 GB"
]

enum PasteMode: Int {
    case autoPaste = 0
    case clipboardOnly = 1
}

enum FormattingMode: Int {
    case casual = 0
    case formal = 1
}

enum HotkeyChoice: Int {
    case rightOption = 0
    case fnKey = 1
}

enum RecordingMode: Int {
    case holdToRecord = 0
    case clickToToggle = 1
}

enum TranscriptionBackend: Int {
    case local = 0
    case cloud = 1
}

class Settings {
    static let shared = Settings()
    private let pasteModeKey = "pasteMode"
    private let modelKey = "whisperModel"
    private let launchAtLoginKey = "launchAtLogin"
    private let formattingModeKey = "formattingMode"
    private let inputDeviceKey = "inputDevice"
    private let hotkeyChoiceKey = "hotkeyChoice"
    private let recordingModeKey = "recordingMode"
    private let backendKey = "transcriptionBackend"
    private let setupCompleteKey = "hasCompletedSetup"

    var pasteMode: PasteMode {
        get { PasteMode(rawValue: UserDefaults.standard.integer(forKey: pasteModeKey)) ?? .autoPaste }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pasteModeKey) }
    }

    var whisperModel: String {
        get {
            let saved = UserDefaults.standard.string(forKey: modelKey)
            return (saved != nil && !saved!.isEmpty) ? saved! : defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    var formattingMode: FormattingMode {
        get { FormattingMode(rawValue: UserDefaults.standard.integer(forKey: formattingModeKey)) ?? .formal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formattingModeKey) }
    }

    var inputDeviceName: String {
        get { UserDefaults.standard.string(forKey: inputDeviceKey) ?? "System Default" }
        set { UserDefaults.standard.set(newValue, forKey: inputDeviceKey) }
    }

    var hotkeyChoice: HotkeyChoice {
        get { HotkeyChoice(rawValue: UserDefaults.standard.integer(forKey: hotkeyChoiceKey)) ?? .rightOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: hotkeyChoiceKey) }
    }

    var recordingMode: RecordingMode {
        get { RecordingMode(rawValue: UserDefaults.standard.integer(forKey: recordingModeKey)) ?? .holdToRecord }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: recordingModeKey) }
    }

    var transcriptionBackend: TranscriptionBackend {
        get { TranscriptionBackend(rawValue: UserDefaults.standard.integer(forKey: backendKey)) ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: backendKey) }
    }

    var hasCompletedSetup: Bool {
        get { UserDefaults.standard.bool(forKey: setupCompleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: setupCompleteKey) }
    }

    var openAIApiKey: String? {
        get { KeychainHelper.read(key: "openai-api-key") }
        set {
            if let val = newValue, !val.isEmpty {
                KeychainHelper.save(key: "openai-api-key", value: val)
            } else {
                KeychainHelper.delete(key: "openai-api-key")
            }
        }
    }

    var hotkeyDescription: String {
        let key = hotkeyChoice == .rightOption ? "Right Option" : "fn"
        let mode = recordingMode == .holdToRecord ? "hold" : "click"
        return "\(mode == "hold" ? "Hold" : "Press") \(key) to \(mode == "hold" ? "record" : "start/stop")"
    }

    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: launchAtLoginKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: launchAtLoginKey)
            setLoginItem(enabled: newValue)
        }
    }

    private func setLoginItem(enabled: Bool) {
        let script: String
        if enabled {
            script = """
            tell application "System Events"
                if not (exists login item "WhisperDictate") then
                    make login item at end with properties {path:"/Applications/WhisperDictate.app", hidden:false}
                end if
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                if exists login item "WhisperDictate" then
                    delete login item "WhisperDictate"
                end if
            end tell
            """
        }
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - Keychain Helper
struct KeychainHelper {
    private static let service = "com.njdevelopments.whisperdictate"

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

// MARK: - Transcription History
class TranscriptionHistory {
    static let shared = TranscriptionHistory()
    private let key = "transcriptionHistory"
    private let maxItems = 20

    struct Entry: Codable {
        let text: String
        let timestamp: Date
    }

    var entries: [Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: key)
            }
        }
    }

    func add(_ text: String) {
        var current = entries
        current.insert(Entry(text: text, timestamp: Date()), at: 0)
        if current.count > maxItems { current = Array(current.prefix(maxItems)) }
        entries = current
    }

    func clear() {
        entries = []
    }
}

// MARK: - Preferences Window
class PreferencesWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var onHotkeyChanged: (() -> Void)?
    private var localViews: [NSView] = []
    private var cloudViews: [NSView] = []
    private var apiKeyField: NSSecureTextField?
    private var modelPopupRef: NSPopUpButton?
    private var modelStatusLabel: NSTextField?
    private var downloadButton: NSButton?
    private var downloadProgress: NSProgressIndicator?
    private var downloadProcess: Process?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "WhisperDictate Settings"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let contentView = NSView(frame: w.contentView!.bounds)
        var y = 560

        // Launch at login
        let loginCheck = NSButton(checkboxWithTitle: "Start at login", target: self, action: #selector(loginToggled(_:)))
        loginCheck.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        loginCheck.state = Settings.shared.launchAtLogin ? .on : .off
        contentView.addSubview(loginCheck)
        y -= 40

        // Hotkey choice
        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        hotkeyLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        hotkeyLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(hotkeyLabel)

        let hotkeyPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        hotkeyPopup.addItems(withTitles: ["Right Option", "fn"])
        hotkeyPopup.selectItem(at: Settings.shared.hotkeyChoice.rawValue)
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged(_:))
        contentView.addSubview(hotkeyPopup)
        y -= 40

        // Recording mode
        let modeLabel = NSTextField(labelWithString: "Recording mode:")
        modeLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        modeLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(modeLabel)

        let modePopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        modePopup.addItems(withTitles: ["Hold to record", "Click to toggle"])
        modePopup.selectItem(at: Settings.shared.recordingMode.rawValue)
        modePopup.target = self
        modePopup.action = #selector(recordingModeChanged(_:))
        contentView.addSubview(modePopup)
        y -= 40

        // Input device
        let deviceLabel = NSTextField(labelWithString: "Input device:")
        deviceLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        deviceLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(deviceLabel)

        let devicePopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        var deviceNames = ["System Default"]
        let inputDevices = getAudioInputDevices()
        deviceNames.append(contentsOf: inputDevices.map { $0.name })
        devicePopup.addItems(withTitles: deviceNames)
        if let idx = deviceNames.firstIndex(of: Settings.shared.inputDeviceName) {
            devicePopup.selectItem(at: idx)
        }
        devicePopup.target = self
        devicePopup.action = #selector(inputDeviceChanged(_:))
        contentView.addSubview(devicePopup)
        y -= 40

        // Paste mode
        let pasteLabel = NSTextField(labelWithString: "After transcription:")
        pasteLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        pasteLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(pasteLabel)

        let pastePopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        pastePopup.addItems(withTitles: ["Auto-paste", "Copy to clipboard"])
        pastePopup.selectItem(at: Settings.shared.pasteMode.rawValue)
        pastePopup.target = self
        pastePopup.action = #selector(pasteModeChanged(_:))
        contentView.addSubview(pastePopup)
        y -= 40

        // Formatting mode
        let fmtLabel = NSTextField(labelWithString: "Formatting:")
        fmtLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        fmtLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(fmtLabel)

        let fmtPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        fmtPopup.addItems(withTitles: ["Casual (raw, keeps fillers)", "Formal (clean, removes fillers)"])
        fmtPopup.selectItem(at: Settings.shared.formattingMode.rawValue)
        fmtPopup.target = self
        fmtPopup.action = #selector(formattingModeChanged(_:))
        contentView.addSubview(fmtPopup)
        y -= 40

        // Separator
        let sep = NSBox(frame: NSRect(x: 20, y: y, width: 340, height: 1))
        sep.boxType = .separator
        contentView.addSubview(sep)
        y -= 20

        // Backend selector
        let backendLabel = NSTextField(labelWithString: "Backend:")
        backendLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        backendLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        contentView.addSubview(backendLabel)

        let backendPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        backendPopup.addItems(withTitles: ["Local (on-device)", "Cloud (OpenAI API)"])
        backendPopup.selectItem(at: Settings.shared.transcriptionBackend.rawValue)
        backendPopup.target = self
        backendPopup.action = #selector(backendChanged(_:))
        contentView.addSubview(backendPopup)
        y -= 40

        // Local-only views: model selector + status
        localViews = []
        let modelLabel = NSTextField(labelWithString: "Whisper model:")
        modelLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        modelLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(modelLabel)
        localViews.append(modelLabel)

        let modelPopup = NSPopUpButton(frame: NSRect(x: 170, y: y - 5, width: 190, height: 30), pullsDown: false)
        for model in availableModels {
            let installed = isModelDownloaded(model)
            modelPopup.addItem(withTitle: installed ? "\(model) (Installed)" : "\(model) (Not Installed)")
        }
        if let idx = availableModels.firstIndex(of: Settings.shared.whisperModel) {
            modelPopup.selectItem(at: idx)
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))
        contentView.addSubview(modelPopup)
        localViews.append(modelPopup)
        self.modelPopupRef = modelPopup

        // Model status label
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: y - 38, width: 220, height: 16)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.isBezeled = false
        statusLabel.isEditable = false
        statusLabel.drawsBackground = false
        contentView.addSubview(statusLabel)
        localViews.append(statusLabel)
        self.modelStatusLabel = statusLabel

        // Download button
        let dlButton = NSButton(title: "Download", target: self, action: #selector(downloadSelectedModel(_:)))
        dlButton.frame = NSRect(x: 250, y: y - 42, width: 110, height: 24)
        dlButton.bezelStyle = .rounded
        dlButton.font = NSFont.systemFont(ofSize: 11)
        dlButton.isHidden = true
        contentView.addSubview(dlButton)
        localViews.append(dlButton)
        self.downloadButton = dlButton

        // Download progress bar (not in localViews — only shown during active download)
        let progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: y - 60, width: 340, height: 6))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        contentView.addSubview(progressBar)
        self.downloadProgress = progressBar

        // Model hint
        let modelHint = NSTextField(labelWithString: "Smaller = faster, larger = more accurate.")
        modelHint.frame = NSRect(x: 20, y: y - 80, width: 340, height: 16)
        modelHint.font = NSFont.systemFont(ofSize: 11)
        modelHint.textColor = .secondaryLabelColor
        contentView.addSubview(modelHint)
        localViews.append(modelHint)

        // Cloud-only views: API key + model info
        cloudViews = []
        let keyLabel = NSTextField(labelWithString: "API Key:")
        keyLabel.frame = NSRect(x: 20, y: y, width: 140, height: 20)
        keyLabel.font = NSFont.systemFont(ofSize: 13)
        contentView.addSubview(keyLabel)
        cloudViews.append(keyLabel)

        let keyField = NSSecureTextField(frame: NSRect(x: 170, y: y - 2, width: 190, height: 24))
        keyField.placeholderString = "sk-..."
        keyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        if let existing = Settings.shared.openAIApiKey {
            keyField.stringValue = existing
        }
        keyField.target = self
        keyField.action = #selector(apiKeyChanged(_:))
        contentView.addSubview(keyField)
        cloudViews.append(keyField)
        self.apiKeyField = keyField

        let cloudHint = NSTextField(labelWithString: "Model: whisper-1  |  ~$0.006/min\nKey stored in Keychain, not plain text.")
        cloudHint.frame = NSRect(x: 20, y: y - 40, width: 340, height: 30)
        cloudHint.font = NSFont.systemFont(ofSize: 11)
        cloudHint.textColor = .secondaryLabelColor
        contentView.addSubview(cloudHint)
        cloudViews.append(cloudHint)

        // Show/hide based on current backend
        let isCloud = Settings.shared.transcriptionBackend == .cloud
        localViews.forEach { $0.isHidden = isCloud }
        cloudViews.forEach { $0.isHidden = !isCloud }

        // Set model status after show/hide so it doesn't get overridden
        updateModelStatus()

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    @objc func loginToggled(_ sender: NSButton) {
        Settings.shared.launchAtLogin = (sender.state == .on)
    }

    @objc func hotkeyChanged(_ sender: NSPopUpButton) {
        Settings.shared.hotkeyChoice = HotkeyChoice(rawValue: sender.indexOfSelectedItem) ?? .rightOption
        onHotkeyChanged?()
    }

    @objc func recordingModeChanged(_ sender: NSPopUpButton) {
        Settings.shared.recordingMode = RecordingMode(rawValue: sender.indexOfSelectedItem) ?? .holdToRecord
        onHotkeyChanged?()
    }

    @objc func pasteModeChanged(_ sender: NSPopUpButton) {
        Settings.shared.pasteMode = PasteMode(rawValue: sender.indexOfSelectedItem) ?? .autoPaste
    }

    @objc func inputDeviceChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title {
            Settings.shared.inputDeviceName = title
        }
    }

    @objc func formattingModeChanged(_ sender: NSPopUpButton) {
        Settings.shared.formattingMode = FormattingMode(rawValue: sender.indexOfSelectedItem) ?? .formal
    }

    @objc func modelChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0 && idx < availableModels.count else { return }
        let model = availableModels[idx]
        Settings.shared.whisperModel = model
        updateModelStatus()

        if !isModelDownloaded(model) {
            let size = modelExpectedSizes[model] ?? "unknown"
            let alert = NSAlert()
            alert.messageText = "Model Not Installed"
            alert.informativeText = "\"\(model)\" is not downloaded yet (\(size)). Would you like to download it now?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Not Now")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                downloadSelectedModel(downloadButton ?? NSButton())
            }
        }
    }

    @objc func backendChanged(_ sender: NSPopUpButton) {
        let backend = TranscriptionBackend(rawValue: sender.indexOfSelectedItem) ?? .local
        Settings.shared.transcriptionBackend = backend
        let isCloud = backend == .cloud
        localViews.forEach { $0.isHidden = isCloud }
        cloudViews.forEach { $0.isHidden = !isCloud }
    }

    @objc func apiKeyChanged(_ sender: NSSecureTextField) {
        let key = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.openAIApiKey = key.isEmpty ? nil : key
    }

    func isModelDownloaded(_ model: String) -> Bool {
        let path = whisperCacheDir + "/\(model).pt"
        return FileManager.default.fileExists(atPath: path)
    }

    func modelFileSizeString(_ model: String) -> String {
        let path = whisperCacheDir + "/\(model).pt"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64 {
            if size >= 1_000_000_000 {
                return String(format: "%.1f GB", Double(size) / 1_000_000_000)
            } else {
                return String(format: "%d MB", size / 1_000_000)
            }
        }
        return modelExpectedSizes[model] ?? "unknown"
    }

    func updateModelStatus() {
        let model = Settings.shared.whisperModel
        let installed = isModelDownloaded(model)
        if installed {
            let size = modelFileSizeString(model)
            modelStatusLabel?.stringValue = "✓ Installed (\(size))"
            modelStatusLabel?.textColor = NSColor.systemGreen
            downloadButton?.isHidden = true
        } else {
            let size = modelExpectedSizes[model] ?? "unknown"
            modelStatusLabel?.stringValue = "Not downloaded (\(size))"
            modelStatusLabel?.textColor = NSColor.secondaryLabelColor
            downloadButton?.isHidden = false
        }
    }

    func refreshModelPopup() {
        guard let popup = modelPopupRef else { return }
        let selectedIdx = popup.indexOfSelectedItem
        popup.removeAllItems()
        for model in availableModels {
            let installed = isModelDownloaded(model)
            popup.addItem(withTitle: installed ? "\(model) (Installed)" : "\(model) (Not Installed)")
        }
        popup.selectItem(at: selectedIdx)
    }

    @objc func downloadSelectedModel(_ sender: NSButton) {
        let model = Settings.shared.whisperModel
        guard !isModelDownloaded(model) else { return }

        downloadButton?.isHidden = true
        downloadProgress?.isHidden = false
        downloadProgress?.doubleValue = 0
        modelStatusLabel?.stringValue = "Downloading \(model)..."
        modelStatusLabel?.textColor = NSColor.systemOrange

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-u", "-c", "import whisper; whisper.load_model('\(model)')"]
            process.environment = [
                "PATH": systemPATH,
                "HOME": NSHomeDirectory()
            ]
            self?.downloadProcess = process

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe

            var stderrOutput = ""
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                stderrOutput += line
                if let range = line.range(of: #"(\d+)%\|"#, options: .regularExpression) {
                    let match = line[range]
                    let digits = match.filter { $0.isNumber }
                    if let pct = Int(digits) {
                        DispatchQueue.main.async {
                            self?.downloadProgress?.doubleValue = Double(pct)
                            self?.modelStatusLabel?.stringValue = "Downloading \(model)... \(pct)%"
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let exitCode = process.terminationStatus
                DispatchQueue.main.async {
                    self?.downloadProcess = nil
                    self?.downloadProgress?.isHidden = true
                    if exitCode == 0 {
                        self?.refreshModelPopup()
                        self?.updateModelStatus()
                    } else {
                        // Extract last meaningful line from traceback
                        let lines = stderrOutput.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        let lastLine = lines.last ?? "exit code \(exitCode)"
                        let errSummary: String
                        if lastLine.contains("No module named") {
                            errSummary = "whisper not installed. Run: pip3 install openai-whisper"
                        } else if lastLine.contains("ModuleNotFoundError") || lastLine.contains("ImportError") {
                            errSummary = "Missing dependency. Run: pip3 install openai-whisper"
                        } else {
                            errSummary = String(lastLine.prefix(100))
                        }
                        self?.modelStatusLabel?.stringValue = "Failed: \(errSummary)"
                        self?.modelStatusLabel?.textColor = NSColor.systemRed
                        self?.downloadButton?.isHidden = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.downloadProcess = nil
                    self?.downloadProgress?.isHidden = true
                    self?.modelStatusLabel?.stringValue = "Python not found. Run: brew install python && pip3 install openai-whisper"
                    self?.modelStatusLabel?.textColor = NSColor.systemRed
                    self?.downloadButton?.isHidden = false
                }
            }
        }
    }
}

// MARK: - History Window
class HistoryWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var scrollView: NSScrollView?
    var stackView: NSStackView?
    let memoDir = NSHomeDirectory() + "/Documents/WhisperDictate-Memos"

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Transcription History"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 360, height: 250)

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        let sv = NSScrollView(frame: NSRect(x: 10, y: 40, width: 440, height: 400))
        sv.autoresizingMask = [.width, .height]
        sv.hasVerticalScroller = true
        sv.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stack
        clipView.drawsBackground = false
        sv.contentView = clipView

        stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8).isActive = true
        stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8).isActive = true
        stack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 8).isActive = true
        stack.widthAnchor.constraint(equalTo: clipView.widthAnchor, constant: -16).isActive = true

        contentView.addSubview(sv)
        self.scrollView = sv
        self.stackView = stack

        let clearBtn = NSButton(title: "Clear History", target: self, action: #selector(clearHistory))
        clearBtn.frame = NSRect(x: 10, y: 8, width: 120, height: 24)
        clearBtn.bezelStyle = .rounded
        contentView.addSubview(clearBtn)

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w

        refresh()
    }

    func refresh() {
        guard let stack = stackView else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let entries = TranscriptionHistory.shared.entries
        if entries.isEmpty {
            let label = NSTextField(labelWithString: "No transcriptions yet.")
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium

        for (index, entry) in entries.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            // Timestamp
            let timeLabel = NSTextField(labelWithString: formatter.string(from: entry.timestamp))
            timeLabel.font = NSFont.systemFont(ofSize: 11)
            timeLabel.textColor = .secondaryLabelColor
            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(timeLabel)

            // Transcription text (selectable)
            let textField = NSTextField(wrappingLabelWithString: entry.text)
            textField.isSelectable = true
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(textField)

            // Save as Memo button
            let memoBtn = NSButton(title: "Save as Memo", target: self, action: #selector(saveMemo(_:)))
            memoBtn.bezelStyle = .rounded
            memoBtn.controlSize = .small
            memoBtn.font = NSFont.systemFont(ofSize: 11)
            memoBtn.tag = index
            memoBtn.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(memoBtn)

            // Copy button
            let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyEntry(_:)))
            copyBtn.bezelStyle = .rounded
            copyBtn.controlSize = .small
            copyBtn.font = NSFont.systemFont(ofSize: 11)
            copyBtn.tag = index
            copyBtn.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(copyBtn)

            // Layout
            NSLayoutConstraint.activate([
                timeLabel.topAnchor.constraint(equalTo: row.topAnchor),
                timeLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),

                textField.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 4),
                textField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: row.trailingAnchor),

                memoBtn.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 4),
                memoBtn.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                memoBtn.bottomAnchor.constraint(equalTo: row.bottomAnchor),

                copyBtn.centerYAnchor.constraint(equalTo: memoBtn.centerYAnchor),
                copyBtn.leadingAnchor.constraint(equalTo: memoBtn.trailingAnchor, constant: 8),
            ])

            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

            // Separator (except last)
            if index < entries.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
        }
    }

    @objc func saveMemo(_ sender: NSButton) {
        let entries = TranscriptionHistory.shared.entries
        guard sender.tag < entries.count else { return }
        let entry = entries[sender.tag]

        // Create memo directory if needed
        try? FileManager.default.createDirectory(atPath: memoDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "memo-\(formatter.string(from: entry.timestamp)).md"
        let path = memoDir + "/\(filename)"

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .long
        displayFormatter.timeStyle = .medium
        let content = "# Memo — \(displayFormatter.string(from: entry.timestamp))\n\n\(entry.text)\n"

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            sender.title = "Saved!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                sender.title = "Save as Memo"
            }
        } catch {
            sender.title = "Error"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                sender.title = "Save as Memo"
            }
        }
    }

    @objc func copyEntry(_ sender: NSButton) {
        let entries = TranscriptionHistory.shared.entries
        guard sender.tag < entries.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entries[sender.tag].text, forType: .string)
        sender.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            sender.title = "Copy"
        }
    }

    @objc func clearHistory() {
        TranscriptionHistory.shared.clear()
        refresh()
    }
}

// MARK: - Permission & Setup Flow (Guided)
class PermissionSetupController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var onComplete: (() -> Void)?
    private var titleLabel: NSTextField?
    private var descLabel: NSTextField?
    private var actionButton: NSButton?
    private var statusLabel: NSTextField?
    private var stepIndicator: NSTextField?
    private var pollTimer: Timer?
    private var currentStep = 0
    private var dynamicViews: [NSView] = []
    private var chosenBackend: TranscriptionBackend = .local
    private var chosenModel: String = defaultModel
    private var setupApiKeyField: NSSecureTextField?
    private var setupProgressBar: NSProgressIndicator?
    private var downloadProcess: Process?

    private var totalSteps: Int { Settings.shared.hasCompletedSetup ? 3 : 6 }

    // Returns true if all permissions are already granted
    func allPermissionsGranted() -> Bool {
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axGranted = AXIsProcessTrusted()
        return micGranted && axGranted
    }

    // Check if user has at least one working backend ready
    func hasWorkingBackend() -> Bool {
        if Settings.shared.transcriptionBackend == .cloud {
            return !(Settings.shared.openAIApiKey ?? "").isEmpty
        }
        // Local backend — check if selected model is downloaded
        let model = Settings.shared.whisperModel
        let modelPath = whisperCacheDir + "/\(model).pt"
        return FileManager.default.fileExists(atPath: modelPath)
    }

    func show() {
        // If permissions are granted AND setup is done AND backend works, skip entirely
        if allPermissionsGranted() && Settings.shared.hasCompletedSetup && hasWorkingBackend() {
            onComplete?()
            return
        }

        // If setup was "completed" but no backend works, re-run the full setup
        if Settings.shared.hasCompletedSetup && !hasWorkingBackend() {
            Settings.shared.hasCompletedSetup = false
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = "WhisperDictate — Setup"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.level = .floating

        let cv = NSView(frame: w.contentView!.bounds)

        // Step indicator
        let stepInd = NSTextField(labelWithString: "")
        stepInd.font = NSFont.systemFont(ofSize: 11)
        stepInd.textColor = .secondaryLabelColor
        stepInd.frame = NSRect(x: 20, y: 220, width: 400, height: 16)
        cv.addSubview(stepInd)
        self.stepIndicator = stepInd

        // Title
        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.frame = NSRect(x: 20, y: 185, width: 400, height: 28)
        cv.addSubview(title)
        self.titleLabel = title

        // Description
        let desc = NSTextField(wrappingLabelWithString: "")
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.textColor = .secondaryLabelColor
        desc.frame = NSRect(x: 20, y: 105, width: 400, height: 70)
        cv.addSubview(desc)
        self.descLabel = desc

        // Status label
        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        status.frame = NSRect(x: 20, y: 65, width: 400, height: 20)
        cv.addSubview(status)
        self.statusLabel = status

        // Action button
        let btn = NSButton(title: "Grant Permission", target: self, action: #selector(actionPressed))
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 110, y: 20, width: 220, height: 32)
        btn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        btn.keyEquivalent = "\r"
        cv.addSubview(btn)
        self.actionButton = btn

        w.contentView = cv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w

        // Figure out which step to start on
        currentStep = 0
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            currentStep = 1
        }
        if AXIsProcessTrusted() && currentStep == 1 {
            currentStep = 2
        }
        showCurrentStep()
    }

    private func clearDynamicViews() {
        dynamicViews.forEach { $0.removeFromSuperview() }
        dynamicViews.removeAll()
        setupApiKeyField = nil
        setupProgressBar = nil
    }

    private func resizeWindow(height: CGFloat) {
        guard let w = window else { return }
        var frame = w.frame
        let diff = height - frame.size.height
        frame.size.height = height
        frame.origin.y -= diff
        w.setFrame(frame, display: true, animate: true)

        // Resize content view to match and reposition fixed elements
        w.contentView?.frame = NSRect(x: 0, y: 0, width: frame.size.width, height: height)
        let top = height - 55
        stepIndicator?.frame.origin.y = top
        titleLabel?.frame.origin.y = top - 30
    }

    private func showCurrentStep() {
        pollTimer?.invalidate()
        pollTimer = nil
        clearDynamicViews()
        actionButton?.isEnabled = true
        actionButton?.isHidden = false
        statusLabel?.stringValue = ""

        switch currentStep {
        case 0: showMicrophoneStep()
        case 1: showAccessibilityStep()
        case 2: showKeychainStep()
        case 3: showHotkeyStep()
        case 4: showBackendChoice()
        case 5: showBackendSetup()
        default: finishSetup()
        }
    }

    // Helper to position desc label relative to the title
    private func positionDesc(height: CGFloat, descHeight: CGFloat = 70) {
        let titleY = titleLabel?.frame.origin.y ?? 0
        descLabel?.frame = NSRect(x: 20, y: titleY - 30 - descHeight, width: 400, height: descHeight)
    }

    // MARK: Step 0 — Microphone
    private func showMicrophoneStep() {
        resizeWindow(height: 260)
        stepIndicator?.stringValue = "Step 1 of \(totalSteps)"
        titleLabel?.stringValue = "Microphone Access"
        positionDesc(height: 260, descHeight: 70)
        descLabel?.stringValue = "WhisperDictate needs microphone access to record your voice for transcription. Click the button below to grant permission."
        actionButton?.title = "Grant Microphone"

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            currentStep = 1
            showCurrentStep()
        }
    }

    // MARK: Step 1 — Accessibility
    private func showAccessibilityStep() {
        resizeWindow(height: 260)
        stepIndicator?.stringValue = "Step 2 of \(totalSteps)"
        titleLabel?.stringValue = "Accessibility Access"
        positionDesc(height: 260, descHeight: 70)
        descLabel?.stringValue = "WhisperDictate needs Accessibility access so it can listen for your hotkey. System Settings will open — find WhisperDictate in the list and toggle it on, then come back here."
        actionButton?.title = "Open Accessibility Settings"

        if AXIsProcessTrusted() {
            currentStep = 2
            showCurrentStep()
        }
    }

    // MARK: Step 2 — Keychain
    private func showKeychainStep() {
        resizeWindow(height: 290)
        stepIndicator?.stringValue = "Step 3 of \(totalSteps)"
        titleLabel?.stringValue = "Keychain Access"
        positionDesc(height: 290, descHeight: 90)
        descLabel?.stringValue = "WhisperDictate stores sensitive data (like API keys) in your Mac's Keychain. You may see a password prompt — enter your Mac password and click \"Always Allow\". This is highly recommended, otherwise you'll have to enter your password every single time."
        actionButton?.title = "Authorize Keychain"
    }

    // MARK: Step 3 — Hotkey & Recording Mode
    private func showHotkeyStep() {
        resizeWindow(height: 340)
        stepIndicator?.stringValue = "Step 4 of \(totalSteps)"
        titleLabel?.stringValue = "Hotkey & Recording Mode"
        positionDesc(height: 340, descHeight: 30)
        descLabel?.stringValue = "Choose how you want to trigger recording. You can change this in Settings."
        actionButton?.title = "Continue"
        statusLabel?.stringValue = ""

        guard let cv = window?.contentView else { return }
        let titleY = titleLabel?.frame.origin.y ?? 0
        var y = Int(titleY) - 80

        // Hotkey choice
        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        hotkeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hotkeyLabel.frame = NSRect(x: 20, y: y, width: 100, height: 20)
        cv.addSubview(hotkeyLabel)
        dynamicViews.append(hotkeyLabel)

        let rightOptRadio = NSButton(radioButtonWithTitle: "  Right Option key", target: self, action: #selector(hotkeyRadioChanged(_:)))
        rightOptRadio.frame = NSRect(x: 130, y: y, width: 160, height: 20)
        rightOptRadio.tag = 0
        rightOptRadio.state = .on
        cv.addSubview(rightOptRadio)
        dynamicViews.append(rightOptRadio)

        let fnRadio = NSButton(radioButtonWithTitle: "  fn key", target: self, action: #selector(hotkeyRadioChanged(_:)))
        fnRadio.frame = NSRect(x: 300, y: y, width: 120, height: 20)
        fnRadio.tag = 1
        fnRadio.state = .off
        cv.addSubview(fnRadio)
        dynamicViews.append(fnRadio)

        y -= 40

        // Recording mode
        let modeLabel = NSTextField(labelWithString: "Recording mode:")
        modeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        modeLabel.frame = NSRect(x: 20, y: y, width: 120, height: 20)
        cv.addSubview(modeLabel)
        dynamicViews.append(modeLabel)

        let holdRadio = NSButton(radioButtonWithTitle: "  Hold to record", target: self, action: #selector(modeRadioChanged(_:)))
        holdRadio.frame = NSRect(x: 150, y: y, width: 140, height: 20)
        holdRadio.tag = 0
        holdRadio.state = .on
        cv.addSubview(holdRadio)
        dynamicViews.append(holdRadio)

        let toggleRadio = NSButton(radioButtonWithTitle: "  Click to toggle", target: self, action: #selector(modeRadioChanged(_:)))
        toggleRadio.frame = NSRect(x: 300, y: y, width: 130, height: 20)
        toggleRadio.tag = 1
        toggleRadio.state = .off
        cv.addSubview(toggleRadio)
        dynamicViews.append(toggleRadio)

        y -= 30

        let holdDesc = NSTextField(labelWithString: "Hold: press and hold the key while speaking, release to transcribe.\nToggle: press once to start, press again to stop and transcribe.")
        holdDesc.font = NSFont.systemFont(ofSize: 11)
        holdDesc.textColor = .secondaryLabelColor
        holdDesc.frame = NSRect(x: 20, y: y - 20, width: 400, height: 30)
        cv.addSubview(holdDesc)
        dynamicViews.append(holdDesc)
    }

    @objc func hotkeyRadioChanged(_ sender: NSButton) {
        Settings.shared.hotkeyChoice = HotkeyChoice(rawValue: sender.tag) ?? .rightOption
    }

    @objc func modeRadioChanged(_ sender: NSButton) {
        Settings.shared.recordingMode = RecordingMode(rawValue: sender.tag) ?? .holdToRecord
    }

    private func saveHotkeyChoice() {
        // Settings already saved via radio handlers, just advance
        currentStep = 4
        showCurrentStep()
    }

    // MARK: Step 4 — Backend Choice
    private func showBackendChoice() {
        resizeWindow(height: 360)
        stepIndicator?.stringValue = "Step 5 of 6"
        titleLabel?.stringValue = "Choose Your Transcription Method"
        positionDesc(height: 360, descHeight: 30)
        descLabel?.stringValue = "You can change this anytime in Settings."
        actionButton?.title = "Continue"
        statusLabel?.stringValue = ""

        guard let cv = window?.contentView else { return }

        // Local option
        let localRadio = NSButton(radioButtonWithTitle: "  Local (On-Device)", target: self, action: #selector(backendRadioChanged(_:)))
        localRadio.frame = NSRect(x: 20, y: 210, width: 400, height: 20)
        localRadio.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        localRadio.tag = 0
        localRadio.state = .on
        cv.addSubview(localRadio)
        dynamicViews.append(localRadio)

        let localDesc = NSTextField(labelWithString: "Completely private. Free, runs entirely on your Mac. No internet needed.")
        localDesc.font = NSFont.systemFont(ofSize: 11)
        localDesc.textColor = .secondaryLabelColor
        localDesc.frame = NSRect(x: 42, y: 190, width: 380, height: 16)
        cv.addSubview(localDesc)
        dynamicViews.append(localDesc)

        // Cloud option
        let cloudRadio = NSButton(radioButtonWithTitle: "  Cloud (OpenAI API)", target: self, action: #selector(backendRadioChanged(_:)))
        cloudRadio.frame = NSRect(x: 20, y: 150, width: 400, height: 20)
        cloudRadio.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        cloudRadio.tag = 1
        cloudRadio.state = .off
        cv.addSubview(cloudRadio)
        dynamicViews.append(cloudRadio)

        let cloudDesc = NSTextField(labelWithString: "Uses OpenAI's whisper-1 model. Fast, no RAM usage. ~$0.006/min.")
        cloudDesc.font = NSFont.systemFont(ofSize: 11)
        cloudDesc.textColor = .secondaryLabelColor
        cloudDesc.frame = NSRect(x: 42, y: 130, width: 380, height: 16)
        cv.addSubview(cloudDesc)
        dynamicViews.append(cloudDesc)

        chosenBackend = .local
    }

    @objc func backendRadioChanged(_ sender: NSButton) {
        chosenBackend = sender.tag == 1 ? .cloud : .local
    }

    // MARK: Step 4 — Backend-Specific Setup
    private func showBackendSetup() {
        if chosenBackend == .cloud {
            showCloudSetup()
        } else {
            showLocalModelSetup()
        }
    }

    private func showCloudSetup() {
        resizeWindow(height: 380)
        stepIndicator?.stringValue = "Step 6 of 6 — API Setup"
        titleLabel?.stringValue = "Set Up OpenAI API"
        positionDesc(height: 380, descHeight: 40)
        descLabel?.stringValue = "You need an OpenAI API key to use cloud transcription. It takes about 30 seconds to set up."
        actionButton?.title = "Finish Setup"
        statusLabel?.stringValue = ""

        guard let cv = window?.contentView else { return }

        // Steps
        let steps = NSTextField(wrappingLabelWithString: "1. Go to platform.openai.com/api-keys\n2. Sign in or create an account\n3. Click \"Create new secret key\"\n4. Copy the key and paste it below")
        steps.font = NSFont.systemFont(ofSize: 12)
        steps.frame = NSRect(x: 20, y: 145, width: 400, height: 80)
        cv.addSubview(steps)
        dynamicViews.append(steps)

        // API key field
        let keyLabel = NSTextField(labelWithString: "API Key:")
        keyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        keyLabel.frame = NSRect(x: 20, y: 115, width: 70, height: 20)
        cv.addSubview(keyLabel)
        dynamicViews.append(keyLabel)

        let keyField = NSSecureTextField(frame: NSRect(x: 95, y: 112, width: 325, height: 26))
        keyField.placeholderString = "sk-..."
        keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cv.addSubview(keyField)
        dynamicViews.append(keyField)
        self.setupApiKeyField = keyField

        let hint = NSTextField(labelWithString: "Key is stored securely in your Mac's Keychain, not in plain text.")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 95, y: 92, width: 325, height: 14)
        cv.addSubview(hint)
        dynamicViews.append(hint)
    }

    private func showLocalModelSetup() {
        resizeWindow(height: 480)
        stepIndicator?.stringValue = "Step 6 of 6 — Model Selection"
        titleLabel?.stringValue = "Choose a Whisper Model"
        positionDesc(height: 480, descHeight: 30)

        let ramBytes = ProcessInfo.processInfo.physicalMemory
        let ramGB = Int(ramBytes / (1024 * 1024 * 1024))
        descLabel?.stringValue = "Your Mac has \(ramGB) GB of RAM. Pick a model based on your needs:"
        actionButton?.title = "Download & Finish"
        statusLabel?.stringValue = ""

        guard let cv = window?.contentView else { return }

        // Determine recommended model
        let recommended: String
        if ramGB >= 32 {
            recommended = "turbo"
        } else if ramGB >= 16 {
            recommended = "small.en"
        } else {
            recommended = "base.en"
        }
        chosenModel = recommended

        struct ModelInfo {
            let name: String
            let size: String
            let speed: String
            let accuracy: String
        }

        let models: [ModelInfo] = [
            ModelInfo(name: "tiny.en", size: "75 MB", speed: "Fastest", accuracy: "Basic"),
            ModelInfo(name: "base.en", size: "140 MB", speed: "Fast", accuracy: "Good"),
            ModelInfo(name: "small.en", size: "465 MB", speed: "Moderate", accuracy: "Great"),
            ModelInfo(name: "medium.en", size: "1.5 GB", speed: "Slower", accuracy: "Excellent"),
            ModelInfo(name: "turbo", size: "1.5 GB", speed: "Fast", accuracy: "Excellent"),
        ]

        var y = 350
        for (i, model) in models.enumerated() {
            let isRec = model.name == recommended
            let installed = FileManager.default.fileExists(atPath: whisperCacheDir + "/\(model.name).pt")

            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(modelRadioChanged(_:)))
            radio.frame = NSRect(x: 20, y: y, width: 20, height: 20)
            radio.tag = i
            radio.state = isRec ? .on : .off
            cv.addSubview(radio)
            dynamicViews.append(radio)

            let nameLabel = NSTextField(labelWithString: model.name)
            nameLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: isRec ? .bold : .regular)
            nameLabel.frame = NSRect(x: 42, y: y, width: 80, height: 18)
            cv.addSubview(nameLabel)
            dynamicViews.append(nameLabel)

            let detailText = "\(model.size)  •  \(model.speed)  •  \(model.accuracy)"
            let detailLabel = NSTextField(labelWithString: detailText)
            detailLabel.font = NSFont.systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.frame = NSRect(x: 130, y: y, width: 200, height: 18)
            cv.addSubview(detailLabel)
            dynamicViews.append(detailLabel)

            // Badge: Recommended or Installed
            if isRec {
                let badge = NSTextField(labelWithString: "Recommended")
                badge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
                badge.textColor = .systemBlue
                badge.frame = NSRect(x: 340, y: y, width: 90, height: 18)
                cv.addSubview(badge)
                dynamicViews.append(badge)
            } else if installed {
                let badge = NSTextField(labelWithString: "Installed")
                badge.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                badge.textColor = .systemGreen
                badge.frame = NSRect(x: 340, y: y, width: 90, height: 18)
                cv.addSubview(badge)
                dynamicViews.append(badge)
            }

            y -= 30
        }

        // RAM recommendation note
        let recNote: String
        if ramGB >= 32 {
            recNote = "With \(ramGB) GB RAM, you can comfortably run any model. Turbo gives the best accuracy with good speed."
        } else if ramGB >= 16 {
            recNote = "With \(ramGB) GB RAM, small.en is the best balance of speed and accuracy. Medium and turbo will work but use more memory."
        } else {
            recNote = "With \(ramGB) GB RAM, base.en is recommended. Larger models may slow down your Mac."
        }
        let note = NSTextField(wrappingLabelWithString: recNote)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: y - 15, width: 400, height: 35)
        cv.addSubview(note)
        dynamicViews.append(note)

        // Progress bar (hidden until download starts)
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 70, width: 400, height: 6))
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = false
        progress.isHidden = true
        cv.addSubview(progress)
        dynamicViews.append(progress)
        self.setupProgressBar = progress
    }

    @objc func modelRadioChanged(_ sender: NSButton) {
        let idx = sender.tag
        if idx >= 0 && idx < availableModels.count {
            chosenModel = availableModels[idx]
        }
    }

    @objc func actionPressed() {
        switch currentStep {
        case 0: requestMicrophone()
        case 1: requestAccessibility()
        case 2: requestKeychain()
        case 3: // Hotkey step — save and advance
            saveHotkeyChoice()
        case 4: // Backend choice — advance to setup
            Settings.shared.transcriptionBackend = chosenBackend
            currentStep = 5
            showCurrentStep()
        case 5: // Final setup
            if chosenBackend == .cloud {
                finishCloudSetup()
            } else {
                finishLocalSetup()
            }
        default: finishSetup()
        }
    }

    private func requestMicrophone() {
        actionButton?.isEnabled = false
        statusLabel?.stringValue = "Requesting permission..."
        statusLabel?.textColor = .systemOrange
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.actionButton?.isEnabled = true
                if granted {
                    self?.statusLabel?.stringValue = "Microphone access granted"
                    self?.statusLabel?.textColor = .systemGreen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.currentStep = 1
                        self?.showCurrentStep()
                    }
                } else {
                    self?.statusLabel?.stringValue = "Permission denied. Open System Settings > Privacy > Microphone to enable."
                    self?.statusLabel?.textColor = .systemRed
                    self?.actionButton?.title = "Try Again"
                }
            }
        }
    }

    private func requestAccessibility() {
        actionButton?.isEnabled = false
        statusLabel?.stringValue = "Waiting for you to enable Accessibility..."
        statusLabel?.textColor = .systemOrange
        window?.level = .normal

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if AXIsProcessTrusted() {
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
                self?.window?.level = .floating
                self?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self?.actionButton?.isEnabled = true
                self?.statusLabel?.stringValue = "Accessibility access granted"
                self?.statusLabel?.textColor = .systemGreen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self?.currentStep = 2
                    self?.showCurrentStep()
                }
            }
        }
    }

    private func requestKeychain() {
        actionButton?.isEnabled = false
        statusLabel?.stringValue = "Authorizing Keychain..."
        statusLabel?.textColor = .systemOrange

        DispatchQueue.global(qos: .userInitiated).async {
            let _ = KeychainHelper.read(key: "openai-api-key")
            let testKey = "permission-setup-test"
            KeychainHelper.save(key: testKey, value: "ok")
            let _ = KeychainHelper.read(key: testKey)
            KeychainHelper.delete(key: testKey)

            DispatchQueue.main.async { [weak self] in
                self?.actionButton?.isEnabled = true
                self?.statusLabel?.stringValue = "Keychain authorized"
                self?.statusLabel?.textColor = .systemGreen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if Settings.shared.hasCompletedSetup {
                        self?.finishSetup()
                    } else {
                        self?.currentStep = 3
                        self?.showCurrentStep()
                    }
                }
            }
        }
    }

    private func finishCloudSetup() {
        let key = setupApiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            statusLabel?.stringValue = "Please enter your API key."
            statusLabel?.textColor = .systemRed
            return
        }
        Settings.shared.transcriptionBackend = .cloud
        Settings.shared.openAIApiKey = key
        Settings.shared.hasCompletedSetup = true
        finishSetup()
    }

    private func finishLocalSetup() {
        Settings.shared.transcriptionBackend = .local
        Settings.shared.whisperModel = chosenModel

        let modelPath = whisperCacheDir + "/\(chosenModel).pt"
        if FileManager.default.fileExists(atPath: modelPath) {
            // Already downloaded
            Settings.shared.hasCompletedSetup = true
            finishSetup()
            return
        }

        // Download the model
        actionButton?.isEnabled = false
        actionButton?.title = "Downloading..."
        setupProgressBar?.isHidden = false
        setupProgressBar?.doubleValue = 0
        statusLabel?.stringValue = "Downloading \(chosenModel)..."
        statusLabel?.textColor = .systemOrange

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["-u", "-c", "import whisper; whisper.load_model('\(self.chosenModel)')"]
            process.environment = [
                "PATH": systemPATH,
                "HOME": NSHomeDirectory()
            ]
            self.downloadProcess = process

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe

            var stderrOutput = ""
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                stderrOutput += line
                if let range = line.range(of: #"(\d+)%\|"#, options: .regularExpression) {
                    let match = line[range]
                    let digits = match.filter { $0.isNumber }
                    if let pct = Int(digits) {
                        DispatchQueue.main.async {
                            self.setupProgressBar?.doubleValue = Double(pct)
                            self.statusLabel?.stringValue = "Downloading \(self.chosenModel)... \(pct)%"
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let exitCode = process.terminationStatus
                DispatchQueue.main.async {
                    self.downloadProcess = nil
                    if exitCode == 0 {
                        Settings.shared.hasCompletedSetup = true
                        self.statusLabel?.stringValue = "Download complete!"
                        self.statusLabel?.textColor = .systemGreen
                        self.setupProgressBar?.isHidden = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            self.finishSetup()
                        }
                    } else {
                        let lines = stderrOutput.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        let lastLine = lines.last ?? "exit code \(exitCode)"
                        let errSummary: String
                        if lastLine.contains("No module named") {
                            errSummary = "whisper not installed. Run: pip3 install openai-whisper"
                        } else if lastLine.contains("ModuleNotFoundError") || lastLine.contains("ImportError") {
                            errSummary = "Missing dependency. Run: pip3 install openai-whisper"
                        } else {
                            errSummary = String(lastLine.prefix(100))
                        }
                        self.statusLabel?.stringValue = "Failed: \(errSummary)"
                        self.statusLabel?.textColor = .systemRed
                        self.setupProgressBar?.isHidden = true
                        self.actionButton?.isEnabled = true
                        self.actionButton?.title = "Skip & Finish"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.downloadProcess = nil
                    self.statusLabel?.stringValue = "Python not found. Run: brew install python && pip3 install openai-whisper"
                    self.statusLabel?.textColor = .systemRed
                    self.setupProgressBar?.isHidden = true
                    self.actionButton?.isEnabled = true
                    self.actionButton?.title = "Skip & Finish"
                }
            }
        }
    }

    private func finishSetup() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.close()
        onComplete?()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Setup Window (First Launch)
class SetupWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    var onComplete: (() -> Void)?
    private var apiKeyField: NSSecureTextField?
    private var cloudDetailBox: NSView?
    private var localDetailBox: NSView?
    private var localModelPopup: NSPopUpButton?

    func show() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to WhisperDictate"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let cv = NSView(frame: w.contentView!.bounds)
        var y = 340

        // Title
        let title = NSTextField(labelWithString: "How would you like to transcribe?")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: 20, y: y, width: 380, height: 24)
        cv.addSubview(title)
        y -= 30

        let subtitle = NSTextField(labelWithString: "You can change this anytime in Settings.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 20, y: y, width: 380, height: 18)
        cv.addSubview(subtitle)
        y -= 40

        // Local button
        let localBtn = NSButton(radioButtonWithTitle: "Local (on-device)", target: self, action: #selector(backendSelected(_:)))
        localBtn.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        localBtn.tag = 0
        localBtn.state = .on
        cv.addSubview(localBtn)
        y -= 22

        let localDesc = NSTextField(labelWithString: "Runs whisper.cpp on your Mac. No internet needed.\nSmaller models are faster, larger are more accurate.")
        localDesc.font = NSFont.systemFont(ofSize: 11)
        localDesc.textColor = .secondaryLabelColor
        localDesc.frame = NSRect(x: 38, y: y - 18, width: 360, height: 30)
        cv.addSubview(localDesc)
        y -= 50

        // Local detail box (model picker)
        let localBox = NSView(frame: NSRect(x: 38, y: y - 20, width: 340, height: 35))
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.font = NSFont.systemFont(ofSize: 13)
        modelLabel.frame = NSRect(x: 0, y: 5, width: 50, height: 20)
        localBox.addSubview(modelLabel)
        let modelPopup = NSPopUpButton(frame: NSRect(x: 55, y: 0, width: 180, height: 30), pullsDown: false)
        modelPopup.addItems(withTitles: availableModels)
        if let idx = availableModels.firstIndex(of: Settings.shared.whisperModel) {
            modelPopup.selectItem(at: idx)
        }
        localBox.addSubview(modelPopup)
        cv.addSubview(localBox)
        self.localDetailBox = localBox
        self.localModelPopup = modelPopup
        y -= 55

        // Cloud button
        let cloudBtn = NSButton(radioButtonWithTitle: "Cloud (OpenAI API)", target: self, action: #selector(backendSelected(_:)))
        cloudBtn.frame = NSRect(x: 20, y: y, width: 200, height: 20)
        cloudBtn.tag = 1
        cloudBtn.state = .off
        cv.addSubview(cloudBtn)
        y -= 22

        let cloudDesc = NSTextField(labelWithString: "Sends audio to OpenAI's whisper-1 API. Faster, no RAM usage.\n~$0.006/min. Requires an API key.")
        cloudDesc.font = NSFont.systemFont(ofSize: 11)
        cloudDesc.textColor = .secondaryLabelColor
        cloudDesc.frame = NSRect(x: 38, y: y - 18, width: 360, height: 30)
        cv.addSubview(cloudDesc)
        y -= 50

        // Cloud detail box (API key)
        let cloudBox = NSView(frame: NSRect(x: 38, y: y - 25, width: 340, height: 40))
        let keyLabel = NSTextField(labelWithString: "API Key:")
        keyLabel.font = NSFont.systemFont(ofSize: 13)
        keyLabel.frame = NSRect(x: 0, y: 10, width: 60, height: 20)
        cloudBox.addSubview(keyLabel)
        let keyField = NSSecureTextField(frame: NSRect(x: 65, y: 5, width: 220, height: 26))
        keyField.placeholderString = "sk-..."
        keyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cloudBox.addSubview(keyField)
        let modelInfo = NSTextField(labelWithString: "(whisper-1)")
        modelInfo.font = NSFont.systemFont(ofSize: 11)
        modelInfo.textColor = .secondaryLabelColor
        modelInfo.frame = NSRect(x: 290, y: 10, width: 80, height: 20)
        cloudBox.addSubview(modelInfo)
        cloudBox.isHidden = true
        cv.addSubview(cloudBox)
        self.cloudDetailBox = cloudBox
        self.apiKeyField = keyField

        // Get Started button
        let startBtn = NSButton(title: "Get Started", target: self, action: #selector(getStarted))
        startBtn.bezelStyle = .rounded
        startBtn.frame = NSRect(x: 150, y: 20, width: 120, height: 32)
        startBtn.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        startBtn.keyEquivalent = "\r"
        cv.addSubview(startBtn)

        w.contentView = cv
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    @objc func backendSelected(_ sender: NSButton) {
        let isCloud = sender.tag == 1
        cloudDetailBox?.isHidden = !isCloud
        localDetailBox?.isHidden = isCloud
    }

    @objc func getStarted() {
        // Determine which radio is selected
        let isCloud = cloudDetailBox?.isHidden == false

        if isCloud {
            let key = apiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if key.isEmpty {
                let alert = NSAlert()
                alert.messageText = "API Key Required"
                alert.informativeText = "Enter your OpenAI API key to use cloud transcription."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            Settings.shared.transcriptionBackend = .cloud
            Settings.shared.openAIApiKey = key
        } else {
            Settings.shared.transcriptionBackend = .local
            if let title = localModelPopup?.selectedItem?.title {
                Settings.shared.whisperModel = title
            }
        }

        Settings.shared.hasCompletedSetup = true
        window?.close()
        onComplete?()
    }

    func windowWillClose(_ notification: Notification) {
        // If they close without choosing, default to local
        if !Settings.shared.hasCompletedSetup {
            Settings.shared.transcriptionBackend = .local
            Settings.shared.hasCompletedSetup = true
            onComplete?()
        }
    }
}

// MARK: - Overlay State
enum OverlayState {
    case recording
    case transcribing
    case downloading(Int) // percentage 0-100
    case done
    case aborted
}

// MARK: - Status Overlay
class StatusOverlay: NSObject {
    private var panel: NSPanel?
    private var statusLabel: NSTextField?
    private var abortButton: NSButton?
    private var recordingDot: NSView?
    private var spinner: NSProgressIndicator?
    private var progressBar: NSProgressIndicator?
    private var pulseAnimation: CAAnimation?
    private var labelLeadingToDot: NSLayoutConstraint?
    private var labelCenterX: NSLayoutConstraint?
    var onAbort: (() -> Void)?

    func show(state: OverlayState) {
        DispatchQueue.main.async {
            if self.panel == nil { self.createPanel() }
            self.updateState(state)
            // Cancel any in-progress hide animation before showing
            self.panel?.contentView?.layer?.removeAllAnimations()
            self.panel?.alphaValue = 0
            self.panel?.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.panel?.animator().alphaValue = 1.0
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.panel?.animator().alphaValue = 0
            }, completionHandler: {
                self.panel?.orderOut(nil)
                self.stopPulse()
            })
        }
    }

    func updateState(_ state: OverlayState, clipboardMode: Bool = false) {
        DispatchQueue.main.async {
            switch state {
            case .recording:
                self.statusLabel?.stringValue = "Recording..."
                self.statusLabel?.textColor = .white
                self.statusLabel?.alignment = .left
                self.recordingDot?.isHidden = false
                self.spinner?.isHidden = true
                self.spinner?.stopAnimation(nil)
                self.progressBar?.isHidden = true
                self.abortButton?.isHidden = false
                self.setLabelCentered(false)
                self.startPulse()
            case .transcribing:
                self.statusLabel?.stringValue = "Transcribing..."
                self.statusLabel?.textColor = .white
                self.statusLabel?.alignment = .left
                self.recordingDot?.isHidden = true
                self.stopPulse()
                self.spinner?.isHidden = false
                self.spinner?.startAnimation(nil)
                self.progressBar?.isHidden = true
                self.abortButton?.isHidden = false
                self.setLabelCentered(false)
            case .downloading(let pct):
                self.statusLabel?.stringValue = "Downloading model... \(pct)%"
                self.statusLabel?.textColor = .white
                self.statusLabel?.alignment = .left
                self.recordingDot?.isHidden = true
                self.stopPulse()
                self.spinner?.isHidden = true
                self.spinner?.stopAnimation(nil)
                self.progressBar?.isHidden = false
                self.progressBar?.doubleValue = Double(pct)
                self.abortButton?.isHidden = false
                self.setLabelCentered(false)
            case .done:
                let text = clipboardMode ? "Copied to Clipboard" : "Done"
                self.statusLabel?.stringValue = text
                self.statusLabel?.textColor = .systemGreen
                self.statusLabel?.alignment = .center
                self.recordingDot?.isHidden = true
                self.stopPulse()
                self.spinner?.isHidden = true
                self.spinner?.stopAnimation(nil)
                self.progressBar?.isHidden = true
                self.abortButton?.isHidden = true
                self.setLabelCentered(true)
                self.flashTint(.systemGreen)
            case .aborted:
                self.statusLabel?.stringValue = "Aborted"
                self.statusLabel?.textColor = .systemOrange
                self.statusLabel?.alignment = .center
                self.recordingDot?.isHidden = true
                self.stopPulse()
                self.spinner?.isHidden = true
                self.spinner?.stopAnimation(nil)
                self.progressBar?.isHidden = true
                self.abortButton?.isHidden = true
                self.setLabelCentered(true)
                self.flashTint(.systemOrange)
            }
        }
    }

    private func setLabelCentered(_ centered: Bool) {
        labelLeadingToDot?.isActive = !centered
        labelCenterX?.isActive = centered
    }

    private func startPulse() {
        guard let dot = recordingDot?.layer else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        recordingDot?.layer?.removeAnimation(forKey: "pulse")
        recordingDot?.layer?.opacity = 1.0
    }

    private func flashTint(_ color: NSColor) {
        guard let contentView = panel?.contentView else { return }
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = color.withAlphaComponent(0.3).cgColor
        flash.toValue = NSColor.clear.cgColor
        flash.duration = 0.6
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        contentView.layer?.add(flash, forKey: "flash")
    }

    private func createPanel() {
        guard let screen = NSScreen.main else { return }

        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 48
        let margin: CGFloat = 40

        let x = (screen.frame.width - panelWidth) / 2
        let y = margin

        let p = NSPanel(
            contentRect: NSRect(x: x, y: y, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        // Vibrancy background
        let vibrancy = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        vibrancy.material = .hudWindow
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = panelHeight / 2
        vibrancy.layer?.masksToBounds = true
        vibrancy.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(vibrancy)

        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = panelHeight / 2
        p.contentView?.layer?.masksToBounds = true

        // Pulsing red dot
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        p.contentView?.addSubview(dot)

        // Spinner
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isIndeterminate = true
        spin.translatesAutoresizingMaskIntoConstraints = false
        spin.isHidden = true
        spin.appearance = NSAppearance(named: .darkAqua)
        p.contentView?.addSubview(spin)

        // Progress bar (for model downloads)
        let progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true
        progressBar.appearance = NSAppearance(named: .darkAqua)
        p.contentView?.addSubview(progressBar)

        // Status label
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        p.contentView?.addSubview(label)

        // Abort button (SF Symbol)
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Abort")
        btn.imagePosition = .imageOnly
        btn.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.target = self
        btn.action = #selector(abortClicked)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        p.contentView?.addSubview(btn)

        // Label constraints: left-aligned (active) and centered (inactive)
        let leadingToDot = label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10)
        let centerX = label.centerXAnchor.constraint(equalTo: p.contentView!.centerXAnchor)
        centerX.isActive = false

        NSLayoutConstraint.activate([
            // Dot
            dot.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 20),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            // Spinner (same position as dot)
            spin.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor),
            spin.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 18),
            spin.widthAnchor.constraint(equalToConstant: 16),
            spin.heightAnchor.constraint(equalToConstant: 16),

            // Progress bar (same position as spinner)
            progressBar.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: p.contentView!.leadingAnchor, constant: 18),
            progressBar.widthAnchor.constraint(equalToConstant: 16),
            progressBar.heightAnchor.constraint(equalToConstant: 16),

            // Label
            label.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor),
            leadingToDot,
            label.trailingAnchor.constraint(lessThanOrEqualTo: btn.leadingAnchor, constant: -8),

            // Abort button
            btn.centerYAnchor.constraint(equalTo: p.contentView!.centerYAnchor),
            btn.trailingAnchor.constraint(equalTo: p.contentView!.trailingAnchor, constant: -14),
            btn.widthAnchor.constraint(equalToConstant: 22),
            btn.heightAnchor.constraint(equalToConstant: 22),
        ])

        self.panel = p
        self.statusLabel = label
        self.abortButton = btn
        self.recordingDot = dot
        self.spinner = spin
        self.progressBar = progressBar
        self.labelLeadingToDot = leadingToDot
        self.labelCenterX = centerX
    }

    @objc func abortClicked() {
        onAbort?()
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotkeyMonitor: HotkeyMonitor!
    let prefsController = PreferencesWindowController()
    let historyController = HistoryWindowController()
    let setupController = SetupWindowController()
    let permissionController = PermissionSetupController()
    let overlay = StatusOverlay()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up Edit menu so Cmd+V/C/X/A work in text fields (menu bar apps lack this by default)
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = {
            let m = NSMenu(title: "Edit")
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            m.addItem(NSMenuItem.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            return m
        }()
        mainMenu.addItem(editMenuItem)
        NSApplication.shared.mainMenu = mainMenu

        // Permission setup (runs every launch, skips if already granted)
        permissionController.onComplete = { [weak self] in
            self?.afterPermissions()
        }
        permissionController.show()
    }

    func afterPermissions() {
        setupMenuAndHotkey()
    }

    func setupMenuAndHotkey() {
        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Whisper Dictate")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Whisper Dictate v3.5.2", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: Settings.shared.hotkeyDescription, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let abortItem = NSMenuItem(title: "Abort Recording", action: #selector(abortRecording), keyEquivalent: "")
        abortItem.isEnabled = false
        menu.addItem(abortItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openPrefs), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Start hotkey monitoring with overlay
        hotkeyMonitor = HotkeyMonitor(statusItem: statusItem, overlay: overlay)
        hotkeyMonitor.start()

        // Wire overlay abort button to hotkeyMonitor
        overlay.onAbort = { [weak self] in
            self?.hotkeyMonitor.abortRecording()
        }

        // Update menu hint when hotkey settings change
        prefsController.onHotkeyChanged = { [weak self] in
            self?.hotkeyMonitor.refreshStatusText()
        }
    }

    @objc func abortRecording() {
        hotkeyMonitor.abortRecording()
    }

    @objc func openHistory() {
        historyController.show()
    }

    @objc func openPrefs() {
        prefsController.show()
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - Audio Device Helpers
struct AudioInputDevice {
    let name: String
    let id: AudioDeviceID
}

func getAudioInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return [] }

    var result: [AudioInputDevice] = []
    for deviceID in deviceIDs {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr else { continue }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamSize, bufferListPointer) == noErr else { continue }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        var inputChannels: UInt32 = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers { inputChannels += buffer.mNumberChannels }
        guard inputChannels > 0 else { continue }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

        result.append(AudioInputDevice(name: name as String, id: deviceID))
    }
    return result
}

func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
    var id = deviceID
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

// MARK: - Audio Recorder
class AudioRecorder {
    var audioRecorder: AVAudioRecorder?
    var audioFile: URL?

    func startRecording() {
        // Set input device if user selected a specific one
        let deviceName = Settings.shared.inputDeviceName
        if deviceName != "System Default" {
            let devices = getAudioInputDevices()
            if let device = devices.first(where: { $0.name == deviceName }) {
                setDefaultInputDevice(device.id)
            }
        }

        let audioFilename = tmpDir + "/whisper-recording-\(Date().timeIntervalSince1970).wav"
        audioFile = URL(fileURLWithPath: audioFilename)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFile!, settings: settings)
            audioRecorder?.record()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        audioRecorder = nil
        return audioFile
    }
}

// MARK: - Smart Formatting
func smartFormat(_ text: String) -> String {
    var result = text

    // Collapse internal newlines into spaces
    result = result.replacingOccurrences(of: "\n", with: " ")

    // Collapse multiple spaces
    while result.contains("  ") {
        result = result.replacingOccurrences(of: "  ", with: " ")
    }

    // Remove filler words (standalone, case-insensitive)
    let fillers = ["\\bum\\b", "\\buh\\b", "\\bah\\b", "\\bumm\\b", "\\buhh\\b", "\\bahh\\b"]
    for filler in fillers {
        if let regex = try? NSRegularExpression(pattern: filler, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
    }

    // Clean up leftover double spaces and comma-space issues from filler removal
    while result.contains("  ") {
        result = result.replacingOccurrences(of: "  ", with: " ")
    }
    result = result.replacingOccurrences(of: " ,", with: ",")
    result = result.replacingOccurrences(of: " .", with: ".")
    result = result.replacingOccurrences(of: ",,", with: ",")

    // Fix standalone "i" -> "I"
    if let regex = try? NSRegularExpression(pattern: "\\bi\\b", options: []) {
        result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "I")
    }

    // Capitalize first character
    if !result.isEmpty {
        result = result.prefix(1).uppercased() + result.dropFirst()
    }

    // Capitalize after sentence-ending punctuation
    if let regex = try? NSRegularExpression(pattern: "([.!?])\\s+(\\w)", options: []) {
        let mutable = NSMutableString(string: result)
        regex.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "$1 $2")
        // NSRegularExpression can't uppercase captures, so do it manually
        var final = result
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            if let range2 = Range(match.range(at: 2), in: result) {
                let upper = result[range2].uppercased()
                final = final.replacingCharacters(in: range2, with: upper)
            }
        }
        result = final
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Transcription
func transcribe(audioFile: URL, processStarted: ((Process) -> Void)? = nil, onProgress: ((Int) -> Void)? = nil, completion: @escaping (String?) -> Void) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: whisperPath)
    process.environment = ["PATH": systemPATH,
                           "HOME": NSHomeDirectory()]
    process.arguments = [
        audioFile.path,
        "--model", Settings.shared.whisperModel,
        "--language", "en",
        "--output_format", "txt",
        "--output_dir", tmpDir
    ]

    // Pipe stderr to catch model download progress
    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    // Read stderr asynchronously for download progress
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
        // Parse tqdm-style progress: "  45%|..." or "100%|..."
        if let range = line.range(of: #"(\d+)%\|"#, options: .regularExpression) {
            let match = line[range]
            let digits = match.filter { $0.isNumber }
            if let pct = Int(digits) {
                onProgress?(pct)
            }
        }
    }

    do {
        try process.run()
        processStarted?(process)
        process.waitUntilExit()

        // Stop reading stderr
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Read transcript
        let baseName = audioFile.deletingPathExtension().lastPathComponent
        let transcriptPath = tmpDir + "/\(baseName).txt"

        if let transcript = try? String(contentsOfFile: transcriptPath, encoding: .utf8) {
            let cleaned: String
            if Settings.shared.formattingMode == .formal {
                cleaned = smartFormat(transcript)
            } else {
                // Casual: collapse newlines, trim, but keep filler words and raw casing
                var raw = transcript.replacingOccurrences(of: "\n", with: " ")
                while raw.contains("  ") { raw = raw.replacingOccurrences(of: "  ", with: " ") }
                cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Cleanup
            try? FileManager.default.removeItem(at: audioFile)
            try? FileManager.default.removeItem(atPath: transcriptPath)

            completion(cleaned)
        } else {
            completion(nil)
        }
    } catch {
        print("Transcription error: \(error)")
        completion(nil)
    }
}

// MARK: - Cloud Transcription (OpenAI API)
func transcribeCloud(audioFile: URL, completion: @escaping (String?) -> Void) {
    guard let apiKey = Settings.shared.openAIApiKey, !apiKey.isEmpty else {
        completion(nil)
        return
    }

    let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    // Model field
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
    body.append("whisper-1\r\n".data(using: .utf8)!)

    // Language field
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
    body.append("en\r\n".data(using: .utf8)!)

    // Audio file
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFile.lastPathComponent)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    if let audioData = try? Data(contentsOf: audioFile) {
        body.append(audioData)
    }
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = body

    URLSession.shared.dataTask(with: request) { data, response, error in
        // Cleanup audio file
        try? FileManager.default.removeItem(at: audioFile)

        if let error = error {
            print("Cloud transcription error: \(error)")
            completion(nil)
            return
        }

        guard let data = data else {
            completion(nil)
            return
        }

        // Parse JSON response: {"text": "..."}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            let cleaned: String
            if Settings.shared.formattingMode == .formal {
                cleaned = smartFormat(text)
            } else {
                var raw = text.replacingOccurrences(of: "\n", with: " ")
                while raw.contains("  ") { raw = raw.replacingOccurrences(of: "  ", with: " ") }
                cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            completion(cleaned)
        } else {
            if let errorStr = String(data: data, encoding: .utf8) {
                print("Cloud transcription API error: \(errorStr)")
            }
            completion(nil)
        }
    }.resume()
}

// MARK: - Global Hotkey Monitor
class HotkeyMonitor {
    let recorder = AudioRecorder()
    var isRecording = false
    var isTranscribing = false
    var fnWasPressed = false
    var rightOptionWasPressed = false
    var eventTap: CFMachPort?
    weak var statusItem: NSStatusItem?
    var transcriptionProcess: Process?
    var aborted = false
    var pendingHide: DispatchWorkItem?
    let overlay: StatusOverlay

    init(statusItem: NSStatusItem, overlay: StatusOverlay) {
        self.statusItem = statusItem
        self.overlay = overlay
    }

    func start() {
        // Permissions are handled by PermissionSetupController before we get here
        setupEventTap()
    }

    func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            updateStatus("Enable Accessibility permissions")
            return
        }

        self.eventTap = eventTap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        refreshStatusText()
    }

    func refreshStatusText() {
        updateStatus("Ready - " + Settings.shared.hotkeyDescription)
        updateMenuHint(Settings.shared.hotkeyDescription)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it (happens during UI interactions)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let hotkey = Settings.shared.hotkeyChoice
        let mode = Settings.shared.recordingMode

        if hotkey == .fnKey {
            handleFnKey(event: event, mode: mode)
        } else {
            handleRightOption(event: event, mode: mode)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - fn key handling
    func handleFnKey(event: CGEvent, mode: RecordingMode) {
        let rawFlags = event.flags.rawValue
        let fnPressed = (rawFlags & 0x00800000) != 0

        if mode == .clickToToggle {
            // Click-to-toggle: act on press edge only
            if fnPressed && !fnWasPressed {
                fnWasPressed = true
                if isTranscribing { return }

                if !isRecording {
                    startRecordingUI()
                } else {
                    stopAndTranscribe()
                }
            } else if !fnPressed {
                fnWasPressed = false
            }
        } else {
            // Hold-to-record: start on press, stop on release
            if fnPressed && !fnWasPressed {
                fnWasPressed = true
                if isTranscribing { return }
                startRecordingUI()
            } else if !fnPressed && fnWasPressed {
                fnWasPressed = false
                if isRecording {
                    stopAndTranscribe()
                }
            }
        }
    }

    // MARK: - Right Option key handling
    func handleRightOption(event: CGEvent, mode: RecordingMode) {
        let flags = event.flags
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let rightOptionDown = flags.contains(.maskAlternate) && keycode == 0x3D

        if mode == .holdToRecord {
            // Hold-to-record (original behavior)
            if rightOptionDown && !rightOptionWasPressed {
                rightOptionWasPressed = true
                if isTranscribing { return }
                startRecordingUI()
            } else if !rightOptionDown && rightOptionWasPressed {
                rightOptionWasPressed = false
                if isRecording {
                    stopAndTranscribe()
                }
            }
        } else {
            // Click-to-toggle
            if rightOptionDown && !rightOptionWasPressed {
                rightOptionWasPressed = true
                if isTranscribing { return }

                if !isRecording {
                    startRecordingUI()
                } else {
                    stopAndTranscribe()
                }
            } else if !rightOptionDown {
                rightOptionWasPressed = false
            }
        }
    }

    // MARK: - Recording actions
    func startRecordingUI() {
        // Cancel any pending hide from a previous transcription
        pendingHide?.cancel()
        pendingHide = nil
        isRecording = true
        aborted = false
        recorder.startRecording()
        let stopHint = Settings.shared.recordingMode == .holdToRecord ? "release to stop" : "press again to stop"
        updateStatus("Recording... (\(stopHint))")
        updateIcon("mic.fill.badge.plus")
        overlay.show(state: .recording)
        setAbortMenuEnabled(true)
    }

    func stopAndTranscribe() {
        isRecording = false
        isTranscribing = true
        updateIcon("arrow.triangle.2.circlepath")
        updateStatus("Transcribing...")
        overlay.updateState(.transcribing)

        guard let audioFile = recorder.stopRecording() else {
            isTranscribing = false
            overlay.hide()
            setAbortMenuEnabled(false)
            return
        }

        let handleResult: (String?) -> Void = { transcript in
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.transcriptionProcess = nil
                self.setAbortMenuEnabled(false)

                if self.aborted {
                    self.aborted = false
                    return
                }

                if let transcript = transcript {
                    TranscriptionHistory.shared.add(transcript)

                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(transcript, forType: .string)

                    if Settings.shared.pasteMode == .autoPaste {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            let vKeyCode: CGKeyCode = 9
                            if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
                               let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) {
                                keyDown.flags = .maskCommand
                                keyUp.flags = .maskCommand
                                keyDown.post(tap: .cghidEventTap)
                                keyUp.post(tap: .cghidEventTap)
                            }
                        }
                        self.updateStatus("Transcribed!")
                    } else {
                        self.updateStatus("Copied to clipboard!")
                    }
                    self.updateIcon("mic.circle")
                    let isClipboard = Settings.shared.pasteMode == .clipboardOnly
                    self.overlay.updateState(.done, clipboardMode: isClipboard)

                    // Use cancellable work item so a quick re-record doesn't get killed
                    self.pendingHide?.cancel()
                    let hideWork = DispatchWorkItem { [weak self] in
                        self?.overlay.hide()
                        self?.refreshStatusText()
                    }
                    self.pendingHide = hideWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWork)
                } else {
                    self.updateStatus("Transcription failed")
                    self.updateIcon("mic.circle")
                    self.overlay.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.refreshStatusText()
                    }
                }
            }
        }

        if Settings.shared.transcriptionBackend == .cloud {
            // Cloud: send to OpenAI API
            transcribeCloud(audioFile: audioFile, completion: handleResult)
        } else {
            // Local: run whisper CLI with download progress
            DispatchQueue.global(qos: .userInitiated).async {
                transcribe(audioFile: audioFile, processStarted: { process in
                    self.transcriptionProcess = process
                }, onProgress: { pct in
                    DispatchQueue.main.async {
                        self.overlay.updateState(.downloading(pct))
                        self.updateStatus("Downloading model... \(pct)%")
                    }
                }, completion: handleResult)
            }
        }
    }

    // MARK: - Abort
    func abortRecording() {
        aborted = true

        if isRecording {
            // Discard audio — never send to Whisper
            if let audioFile = recorder.stopRecording() {
                try? FileManager.default.removeItem(at: audioFile)
            }
        }

        if isTranscribing {
            transcriptionProcess?.terminate()
            transcriptionProcess = nil
        }

        isRecording = false
        isTranscribing = false

        updateStatus("Aborted")
        updateIcon("mic.circle")
        overlay.updateState(.aborted)
        setAbortMenuEnabled(false)

        pendingHide?.cancel()
        let hideWork = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
            self?.refreshStatusText()
            self?.aborted = false
        }
        pendingHide = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hideWork)
    }

    func setAbortMenuEnabled(_ enabled: Bool) {
        DispatchQueue.main.async {
            if let menu = self.statusItem?.menu {
                // Abort item is at index 5
                menu.item(at: 5)?.isEnabled = enabled
            }
        }
    }

    func updateStatus(_ status: String) {
        DispatchQueue.main.async {
            if let menu = self.statusItem?.menu {
                menu.item(at: 2)?.title = "Status: \(status)"
            }
        }
    }

    func updateMenuHint(_ hint: String) {
        DispatchQueue.main.async {
            if let menu = self.statusItem?.menu {
                menu.item(at: 3)?.title = hint
            }
        }
    }

    func updateIcon(_ symbolName: String) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Whisper Dictate")
                button.image?.isTemplate = true
            }
        }
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
