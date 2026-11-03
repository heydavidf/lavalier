import AppKit
import ServiceManagement
import LavalierCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let settings: AppSettings
    private let store: KeychainStore
    var onSettingsChanged: (() -> Void)?
    /// True while the Shortcuts tab waits for a new shortcut; the app pauses its own shortcut watching meanwhile.
    var onRecordingChanged: ((Bool) -> Void)?

    /// Tab indexes. Shortcuts is last so the existing `show(tab: 1)` still opens Keys.
    static let shortcutsTab = 3

    // General
    private let hotkeySummary = NSTextField(wrappingLabelWithString: "")
    // Shortcuts
    private let shortcutList = NSStackView()
    private let addShortcutButton = NSButton(title: "Add Shortcut…", target: nil, action: nil)
    private let cancelRecordingButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let recordingPrompt = NSTextField(wrappingLabelWithString: "")
    private let inputMonitoringLine = NSTextField(wrappingLabelWithString: "")
    private var recordingMonitor: Any?
    private var pendingModifier: ModifierKey?
    private let cleanupCheck = NSButton(checkboxWithTitle: "Clean up with Claude Haiku 5.5 (fillers, punctuation, corrections)", target: nil, action: nil)
    private let keytermsCheck = NSButton(checkboxWithTitle: "Also send the dictionary to ElevenLabs as keyterms (max 50, +20% credits)", target: nil, action: nil)
    private let logCheck = NSButton(checkboxWithTitle: "Keep a local text log of transcripts and timings (no audio)", target: nil, action: nil)
    private let soundCheck = NSButton(checkboxWithTitle: "Play a short sound when listening starts and stops", target: nil, action: nil)
    private let indicatorCheck = NSButton(checkboxWithTitle: "Show the floating indicator with the live transcript while dictating", target: nil, action: nil)
    private let glyphPopup = NSPopUpButton()
    private let glyphNote = NSTextField(wrappingLabelWithString: "")
    private let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginNote = NSTextField(wrappingLabelWithString: "")
    // Keys
    private let elevenField = NSSecureTextField()
    private let anthropicField = NSSecureTextField()
    private let elevenStatus = NSTextField(labelWithString: "")
    private let anthropicStatus = NSTextField(labelWithString: "")
    private let testResult = NSTextField(wrappingLabelWithString: "")
    // Dictionary
    private let dictionaryView = NSTextView()

    init(settings: AppSettings, store: KeychainStore) {
        self.settings = settings
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Lavalier Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Int = 0) {
        load()
        (window?.contentView as? NSTabView)?.selectTabViewItem(at: tab)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = NSTabView(frame: window!.contentView!.bounds)
        tabs.autoresizingMask = [.width, .height]
        tabs.addTabViewItem(makeTab("General", view: buildGeneral()))
        tabs.addTabViewItem(makeTab("Keys", view: buildKeys()))
        tabs.addTabViewItem(makeTab("Dictionary", view: buildDictionary()))
        tabs.addTabViewItem(makeTab("Shortcuts", view: buildShortcuts()))
        window?.contentView = tabs
    }

    private func makeTab(_ label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func verticalStack(in container: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        ])
        return stack
    }

    // MARK: General

    private func buildGeneral() -> NSView {
        let view = NSView()
        let stack = verticalStack(in: view)
        let row = NSStackView()
        row.orientation = .horizontal
        row.addArrangedSubview(NSTextField(labelWithString: "Push-to-talk:"))
        hotkeySummary.preferredMaxLayoutWidth = 360
        row.addArrangedSubview(hotkeySummary)
        row.addArrangedSubview(NSButton(title: "Change…", target: self, action: #selector(openShortcutsTab)))
        stack.addArrangedSubview(row)
        let glyphRow = NSStackView()
        glyphRow.orientation = .horizontal
        glyphRow.addArrangedSubview(NSTextField(labelWithString: "Menu-bar icon:"))
        glyphPopup.removeAllItems()
        for style in MenuBarGlyphStyle.allCases {
            glyphPopup.addItem(withTitle: style.label)
            glyphPopup.lastItem?.image = MenuBarGlyph.image(style: style, state: .idle)
        }
        glyphPopup.target = self
        glyphPopup.action = #selector(glyphChanged)
        glyphRow.addArrangedSubview(glyphPopup)
        stack.addArrangedSubview(glyphRow)
        glyphNote.preferredMaxLayoutWidth = 540
        glyphNote.textColor = .secondaryLabelColor
        glyphNote.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(glyphNote)
        for check in [cleanupCheck, keytermsCheck, soundCheck, indicatorCheck, logCheck] {
            check.target = self
            check.action = #selector(checkChanged)
            stack.addArrangedSubview(check)
        }
        loginCheck.target = self
        loginCheck.action = #selector(loginChanged)
        stack.addArrangedSubview(loginCheck)
        loginNote.preferredMaxLayoutWidth = 540
        loginNote.textColor = .secondaryLabelColor
        loginNote.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(loginNote)
        let logPath = NSTextField(wrappingLabelWithString: "Log file: \(TimingLog.fileURL().path)")
        logPath.textColor = .secondaryLabelColor
        logPath.preferredMaxLayoutWidth = 540
        logPath.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(logPath)
        let note = NSTextField(wrappingLabelWithString: "Dictations under 4 words are inserted as heard, without the Claude step. Hold the key, speak, release; the text appears at the cursor.")
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(note)
        return view
    }

    @objc private func openShortcutsTab() {
        (window?.contentView as? NSTabView)?.selectTabViewItem(at: Self.shortcutsTab)
    }

    @objc private func glyphChanged() {
        let style = MenuBarGlyphStyle.allCases[max(0, glyphPopup.indexOfSelectedItem)]
        settings.menuBarGlyph = style
        glyphNote.stringValue = style.blurb
        onSettingsChanged?()
    }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginItem()
        } catch {
            loginNote.stringValue = "Could not change the login item: \(error.localizedDescription)"
            refreshLoginItem(keepNote: true)
        }
    }

    private func refreshLoginItem(keepNote: Bool = false) {
        let status = SMAppService.mainApp.status
        loginCheck.state = status == .enabled ? .on : .off
        if keepNote { return }
        switch status {
        case .enabled: loginNote.stringValue = "Registered. Listed in System Settings > General > Login Items & Extensions. Keep the app at \(Bundle.main.bundlePath)."
        case .requiresApproval: loginNote.stringValue = "Waiting for approval in System Settings > General > Login Items & Extensions."
        case .notFound: loginNote.stringValue = "Not registered."
        default: loginNote.stringValue = "Not registered."
        }
    }

    @objc private func checkChanged() {
        settings.cleanupEnabled = cleanupCheck.state == .on
        settings.sendKeyterms = keytermsCheck.state == .on
        settings.timingLogEnabled = logCheck.state == .on
        settings.soundCuesEnabled = soundCheck.state == .on
        settings.indicatorEnabled = indicatorCheck.state == .on
        onSettingsChanged?()
    }

    // MARK: Keys

    private func buildKeys() -> NSView {
        let view = NSView()
        let stack = verticalStack(in: view)
        let intro = NSTextField(wrappingLabelWithString: "Keys are stored in your macOS Keychain (service \"Lavalier\") and nowhere else. Paste a key and click Save. Fields stay blank on purpose; the status line shows whether a key is stored.")
        intro.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(keyRow("ElevenLabs API key", field: elevenField, status: elevenStatus, saveTag: 0))
        stack.addArrangedSubview(keyRow("Anthropic API key", field: anthropicField, status: anthropicStatus, saveTag: 1))
        let test = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        stack.addArrangedSubview(test)
        testResult.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(testResult)
        return view
    }

    private func keyRow(_ title: String, field: NSSecureTextField, status: NSTextField, saveTag: Int) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        box.addArrangedSubview(label)
        let line = NSStackView()
        line.orientation = .horizontal
        field.placeholderString = "paste key here"
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey(_:)))
        save.tag = saveTag
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey(_:)))
        remove.tag = saveTag
        line.addArrangedSubview(field)
        line.addArrangedSubview(save)
        line.addArrangedSubview(remove)
        box.addArrangedSubview(line)
        status.textColor = .secondaryLabelColor
        box.addArrangedSubview(status)
        return box
    }

    private func account(for tag: Int) -> KeyAccount { tag == 0 ? .elevenLabs : .anthropic }

    @objc private func saveKey(_ sender: NSButton) {
        let account = account(for: sender.tag)
        let field = sender.tag == 0 ? elevenField : anthropicField
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { testResult.stringValue = "Nothing to save: the field is empty."; return }
        do {
            try store.set(value, for: account)
            field.stringValue = ""
            testResult.stringValue = "\(account.service.rawValue) key saved to the Keychain."
        } catch {
            Log.app.error("keychain save failed: \(String(describing: error), privacy: .public)")
            testResult.stringValue = "Could not save the key to the Keychain. Make sure your login keychain is unlocked, then try again."
        }
        refreshKeyStatus()
        onSettingsChanged?()
    }

    @objc private func removeKey(_ sender: NSButton) {
        let account = account(for: sender.tag)
        do {
            try store.delete(account)
            testResult.stringValue = "\(account.service.rawValue) key removed."
        } catch {
            Log.app.error("keychain remove failed: \(String(describing: error), privacy: .public)")
            testResult.stringValue = "Could not remove the \(account.service.rawValue) key from the Keychain. Make sure your login keychain is unlocked, then try again."
        }
        refreshKeyStatus()
        onSettingsChanged?()
    }

    private func refreshKeyStatus() {
        elevenStatus.stringValue = store.has(.elevenLabs) ? "Key present in Keychain" : "No key stored"
        anthropicStatus.stringValue = store.has(.anthropic) ? "Key present in Keychain" : "No key stored"
    }

    @objc private func testConnection() {
        testResult.stringValue = "Testing…"
        let store = self.store
        Task { @MainActor in
            var lines: [String] = []
            do {
                let key = try KeychainKeyProvider(store: store).key(for: .elevenLabs)
                let sub = try await ElevenLabsAccount.fetchSubscription(apiKey: key)
                lines.append("ElevenLabs OK: \(sub.tier) plan, \(sub.creditsRemaining) credits remaining.")
            } catch let e as DictationError { lines.append("ElevenLabs: \(e.userMessage)") } catch { lines.append("ElevenLabs: \(error)") }
            do {
                let key = try KeychainKeyProvider(store: store).key(for: .anthropic)
                try await ClaudeClient(apiKey: key).testConnection()
                lines.append("Anthropic OK: key accepted.")
            } catch let e as DictationError { lines.append("Anthropic: \(e.userMessage)") } catch { lines.append("Anthropic: \(error)") }
            testResult.stringValue = lines.joined(separator: "\n")
        }
    }

    // MARK: Dictionary

    private func buildDictionary() -> NSView {
        let view = NSView()
        let stack = verticalStack(in: view)
        let intro = NSTextField(wrappingLabelWithString: "One name or word per line, spelled the way you want it written. Saved as plain text at \(PersonalDictionary.fileURL().path).")
        intro.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(intro)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 540).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        dictionaryView.isRichText = false
        dictionaryView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        dictionaryView.isAutomaticQuoteSubstitutionEnabled = false
        dictionaryView.isAutomaticSpellingCorrectionEnabled = false
        dictionaryView.autoresizingMask = [.width]
        dictionaryView.minSize = NSSize(width: 0, height: 240)
        dictionaryView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        dictionaryView.isVerticallyResizable = true
        dictionaryView.textContainer?.widthTracksTextView = true
        scroll.documentView = dictionaryView
        stack.addArrangedSubview(scroll)
        let save = NSButton(title: "Save Dictionary", target: self, action: #selector(saveDictionary))
        stack.addArrangedSubview(save)
        return view
    }

    @objc private func saveDictionary() {
        let terms = PersonalDictionary.parse(dictionaryView.string)
        do {
            try PersonalDictionary.save(terms)
            dictionaryView.string = PersonalDictionary.serialise(terms)
            onSettingsChanged?()
        } catch {
            testResult.stringValue = "Could not save the dictionary: \(error)"
        }
    }

    // MARK: Shortcuts

    private func buildShortcuts() -> NSView {
        let view = NSView()
        let stack = verticalStack(in: view)
        let intro = NSTextField(wrappingLabelWithString: "Hold any of these to dictate, and let go to finish. You can have several: a modifier key on its own (such as Right Control or fn), a key or key combination (such as F13 or ⌃⌥Space), or an extra mouse button (middle or side buttons).")
        intro.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(intro)
        shortcutList.orientation = .vertical
        shortcutList.alignment = .leading
        shortcutList.spacing = 10
        stack.addArrangedSubview(shortcutList)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        addShortcutButton.target = self
        addShortcutButton.action = #selector(startRecording)
        cancelRecordingButton.target = self
        cancelRecordingButton.action = #selector(cancelRecording)
        cancelRecordingButton.isHidden = true
        buttons.addArrangedSubview(addShortcutButton)
        buttons.addArrangedSubview(cancelRecordingButton)
        stack.addArrangedSubview(buttons)
        recordingPrompt.preferredMaxLayoutWidth = 540
        stack.addArrangedSubview(recordingPrompt)
        inputMonitoringLine.preferredMaxLayoutWidth = 540
        inputMonitoringLine.textColor = .secondaryLabelColor
        inputMonitoringLine.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(inputMonitoringLine)
        stack.addArrangedSubview(NSButton(title: "Open Input Monitoring Settings", target: self, action: #selector(openInputMonitoring)))
        return view
    }

    private func reloadShortcuts() {
        let list = settings.hotkeys
        hotkeySummary.stringValue = list.spokenList
        for v in shortcutList.arrangedSubviews { shortcutList.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, binding) in list.enumerated() {
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 2
            let line = NSStackView()
            line.orientation = .horizontal
            let label = NSTextField(labelWithString: binding.label)
            label.font = .boldSystemFont(ofSize: 13)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
            line.addArrangedSubview(label)
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeShortcut(_:)))
            remove.tag = i
            remove.isEnabled = list.count > 1
            remove.toolTip = list.count > 1 ? nil : "Add another shortcut first; there must always be one."
            line.addArrangedSubview(remove)
            box.addArrangedSubview(line)
            if let note = binding.note {
                let n = NSTextField(wrappingLabelWithString: note)
                n.preferredMaxLayoutWidth = 520
                n.textColor = .secondaryLabelColor
                n.font = .systemFont(ofSize: 11)
                box.addArrangedSubview(n)
            }
            shortcutList.addArrangedSubview(box)
        }
        let needsInput = list.contains { $0.isKeyboardKey || $0.isMouse }
        let status = Permission.inputMonitoring.status
        inputMonitoringLine.stringValue = "Keyboard keys and mouse buttons need Input Monitoring (System Settings > Privacy & Security > Input Monitoring). Lavalier: \(status.label)."
            + (needsInput && status != .granted ? " Until it is granted, those shortcuts do nothing." : "")
    }

    @objc private func removeShortcut(_ sender: NSButton) {
        var list = settings.hotkeys
        guard list.count > 1, list.indices.contains(sender.tag) else { return }
        let removed = list.remove(at: sender.tag)
        settings.hotkeys = list
        Log.app.notice("shortcut removed: \(removed.label, privacy: .public); now \(list.spokenList, privacy: .public)")
        reloadShortcuts()
        onSettingsChanged?()
    }

    @objc private func openInputMonitoring() { Permission.inputMonitoring.openSettings() }

    /// Waits for the next key, modifier key or extra mouse button pressed while this window is in front.
    @objc private func startRecording() {
        guard recordingMonitor == nil else { return }
        pendingModifier = nil
        onRecordingChanged?(true)
        addShortcutButton.isEnabled = false
        cancelRecordingButton.isHidden = false
        recordingPrompt.textColor = .labelColor
        recordingPrompt.stringValue = "Press the key, key combination or mouse button you want to hold. A modifier key on its own (such as fn) counts when you let go of it. Escape cancels."
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.record(event) ? nil : event
        }
    }

    @objc private func cancelRecording() { stopRecording(message: "Cancelled; nothing changed.") }

    private func stopRecording(message: String) {
        if let m = recordingMonitor { NSEvent.removeMonitor(m) }
        let wasRecording = recordingMonitor != nil
        recordingMonitor = nil
        pendingModifier = nil
        addShortcutButton.isEnabled = true
        cancelRecordingButton.isHidden = true
        if wasRecording {
            recordingPrompt.stringValue = message
            onRecordingChanged?(false)
        }
    }

    /// Returns true when the event was used by the recorder.
    private func record(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            let mods = KeyModifiers(flagsRaw: UInt64(event.modifierFlags.rawValue))
            if event.keyCode == 53 && mods.isEmpty { cancelRecording(); return true }
            add(.key(code: Int64(event.keyCode), modifiers: mods))
            return true
        case .flagsChanged:
            guard let key = ModifierKey(keyCode: Int64(event.keyCode)) else { return false }
            let flags = UInt64(event.modifierFlags.rawValue)
            let fnHeld = flags & CGEventFlags.maskSecondaryFn.rawValue != 0
            if flags & key.deviceFlagBit != 0 {
                // Pressed. Only a modifier pressed on its own can become a modifier shortcut.
                var others = KeyModifiers(flagsRaw: flags)
                others.remove(KeyModifiers(flagsRaw: key.classMaskRaw))
                pendingModifier = (others.isEmpty && (key == .fn || !fnHeld)) ? key : nil
            } else if pendingModifier == key {
                add(.modifier(key: key))
            } else {
                pendingModifier = nil
            }
            return false
        case .otherMouseDown:
            let button = Int64(event.buttonNumber)
            guard HotkeyBinding.acceptsMouseButton(button) else { return false }
            add(.mouse(button: button))
            return true
        default:
            return false
        }
    }

    private func add(_ binding: HotkeyBinding) {
        var list = settings.hotkeys
        if list.contains(binding) {
            stopRecording(message: "\(binding.label) is already a shortcut.")
            return
        }
        list.append(binding)
        settings.hotkeys = list
        Log.app.notice("shortcut added: \(binding.label, privacy: .public); now \(list.spokenList, privacy: .public)")
        stopRecording(message: "Added \(binding.label). Hold it to dictate.")
        reloadShortcuts()
        onSettingsChanged?()
    }

    // MARK: Load / close

    private func load() {
        reloadShortcuts()
        cleanupCheck.state = settings.cleanupEnabled ? .on : .off
        keytermsCheck.state = settings.sendKeyterms ? .on : .off
        logCheck.state = settings.timingLogEnabled ? .on : .off
        soundCheck.state = settings.soundCuesEnabled ? .on : .off
        indicatorCheck.state = settings.indicatorEnabled ? .on : .off
        glyphPopup.selectItem(at: MenuBarGlyphStyle.allCases.firstIndex(of: settings.menuBarGlyph) ?? 0)
        glyphNote.stringValue = settings.menuBarGlyph.blurb
        refreshLoginItem()
        refreshKeyStatus()
        testResult.stringValue = ""
        dictionaryView.string = PersonalDictionary.serialise(PersonalDictionary.load())
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(message: "")
        saveDictionary()
        elevenField.stringValue = ""
        anthropicField.stringValue = ""
    }
}
