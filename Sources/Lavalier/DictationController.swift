import AppKit
import AVFoundation
import LavalierCore

/// Glue between the key, the microphone, the pipeline, insertion and the menu.
@MainActor
final class DictationController: NSObject, StatusMenuDelegate {
    /// A held key is released automatically after this long, so the microphone can never stay open.
    static let maximumHoldSeconds: TimeInterval = DictationLimits.maximumHoldSeconds  // 10 min (was 120 s)
    /// After release, the pipeline and insertion must finish within this time or the dictation is abandoned.
    static let processingDeadlineSeconds: TimeInterval = DictationLimits.baseProcessingSeconds  // plus 0.05 s per held second
    /// How long the launch cue stays on screen.
    static let launchCueSeconds: TimeInterval = 6

    private let settings = AppSettings.shared
    private let store = KeychainStore()
    private let status: StatusItemController
    private let reachability = Reachability()
    private let inserter = TextInserter()
    private let hud = DictationHUD()
    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")
    private var hotkey: HotkeyMonitor
    private var capture: AudioCapture?
    private var pipeline: DictationPipeline
    private var usage = UsageTally.load()
    private var subscription: ElevenLabsSubscription?
    private var subscriptionFetchedAt: Date?
    private var lastDictation: String?
    private var busy = false
    /// When the key went down, and the processing deadline for the current dictation.
    private var holdStartedAt = Date()
    private var processingDeadline = DictationController.processingDeadlineSeconds
    private var applyPending = false
    private var currentTask: Task<Void, Never>?
    private var resetTimer: Timer?
    private var holdTimer: Timer?
    private var processingTimer: Timer?
    private var settingsWindow: SettingsWindowController?
    private var permissionsWindow: PermissionsWindowController?
    /// Set when the one-time hotkey migration changed the key at this launch, for the launch cue.
    private var migratedHotkeyFrom: HotkeyChoice?

    override init() {
        migratedHotkeyFrom = settings.migrateHotkeyAwayFromConflicts()
        status = StatusItemController(glyphStyle: settings.menuBarGlyph)
        hotkey = HotkeyMonitor(bindings: settings.hotkeys)
        pipeline = DictationController.makePipeline(settings: settings, store: store)
        super.init()
        status.delegate = self
        hotkey.onTransition = { [weak self] t in self?.handle(t) }
        hotkey.onOtherKeyHeld = { [weak self] other in self?.otherKeyHeld(other) }
        startSound?.volume = 0.5
        stopSound?.volume = 0.5
    }

    private static func makePipeline(settings: AppSettings, store: KeychainStore) -> DictationPipeline {
        var config = PipelineConfig()
        config.cleanupEnabled = settings.cleanupEnabled
        config.sendKeyterms = settings.sendKeyterms
        return DictationPipeline(keys: KeychainKeyProvider(store: store), dictionary: { PersonalDictionary.load() }, config: config)
    }

    func start() {
        let bundle = Bundle.main
        let version = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        Log.app.notice("launch: Lavalier \(version, privacy: .public) at \(bundle.bundlePath, privacy: .public), shortcuts \(self.settings.hotkeys.spokenList, privacy: .public), glyph \(self.settings.menuBarGlyph.rawValue, privacy: .public)")
        if let from = migratedHotkeyFrom {
            Log.app.notice("hotkey moved from \(from.rawValue, privacy: .public) to \(self.settings.hotkey.rawValue, privacy: .public) (conflict with another tool)")
        }
        logPermissions("at launch")
        refreshMenuStatics()
        applyState()
        let missing = Permission.missingRequired
        let decision = OnboardingPolicy.atLaunch(missingRequired: !missing.isEmpty, dismissed: settings.onboardingDismissed)
        settings.onboardingDismissed = decision.dismissed
        if decision.showWindow {
            menuOpenPermissions()
        } else if !store.has(.elevenLabs) || !store.has(.anthropic) {
            menuOpenSettings()
            settingsWindow?.show(tab: 1)
        }
        menuRefreshUsage()
        showLaunchCue(missing: missing)
        // The status item's window has no frame yet at creation; log where it ended up once the menu bar laid it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Log.app.notice("status item placement after 1.5 s: \(self.status.placementDescription, privacy: .public)")
            if self.status.looksHidden {
                self.hud.show(.message("Lavalier is running, but its icon did not fit in the menu bar (the bar is full). Hold \(self.settings.hotkeys.spokenList) to dictate anyway.", isError: false), for: DictationController.launchCueSeconds)
            }
        }
    }

    /// Something visible on launch even when the menu-bar icon is hidden by a full menu bar.
    private func showLaunchCue(missing: [Permission]) {
        var text = "Lavalier is running."
        if !missing.isEmpty {
            text += " Grant \(missing.map(\.title).joined(separator: " and ")) in the Permissions window to start dictating."
        } else if let from = migratedHotkeyFrom {
            text += " Push-to-talk key is now \(settings.hotkeys.spokenList); \(from.label) collided with another tool. Change it in Settings."
        } else {
            text += " Hold \(settings.hotkeys.spokenList) to dictate."
        }
        hud.show(.message(text, isError: false), for: DictationController.launchCueSeconds)
    }

    private func logPermissions(_ when: String) {
        let parts = Permission.allCases.map { "\($0.title)=\($0.status.label)" }.joined(separator: ", ")
        Log.permissions.notice("\(when, privacy: .public): \(parts, privacy: .public); keys: elevenlabs \(self.store.has(.elevenLabs) ? "present" : "missing", privacy: .public), anthropic \(self.store.has(.anthropic) ? "present" : "missing", privacy: .public)")
    }

    func shutdown() {
        hotkey.stop()
        capture?.stop()
        try? usage.save()
        Log.app.notice("shutdown")
    }

    // MARK: State

    /// Recomputes idle/needs-setup and (re)starts the key monitor. Deferred while a dictation is running so
    /// the key tracker is never replaced between a press and its release.
    private func applyState() {
        if busy { applyPending = true; return }
        applyPending = false
        hotkey.update(bindings: settings.hotkeys)
        guard settings.dictationEnabled else {
            hotkey.stop()
            status.set(state: .disabled)
            status.setHotkey(label: settings.hotkeys.spokenList, monitorKind: nil)
            return
        }
        if !store.has(.elevenLabs) {
            hotkey.stop()
            status.set(state: .needsSetup("ElevenLabs key missing. Open Settings > Keys."))
            status.setHotkey(label: settings.hotkeys.spokenList, monitorKind: nil)
            return
        }
        let started = hotkey.start()
        status.setHotkey(label: settings.hotkeys.spokenList, monitorKind: hotkey.mechanismDescription)
        if !started {
            status.set(state: .needsSetup("Accessibility (or Input Monitoring) needed to see the key. Open Permissions."))
        } else if Permission.accessibility.status != .granted {
            // A listen-only tap can be created without the grant, but text insertion needs Accessibility
            // and the tap may receive nothing until it is granted.
            status.set(state: .needsSetup("Accessibility permission needed to see the key and insert text. Open Permissions."))
        } else if Permission.microphone.status == .denied {
            status.set(state: .needsSetup("Microphone permission is off. Open Permissions."))
        } else {
            status.set(state: .idle)
        }
    }

    /// A dictation just failed on a missing permission (revoked, or never granted): bring the Permissions
    /// window back unless the user has closed it since launch. Not called from `applyState`, which the window's
    /// own refresh triggers; that would recurse.
    private func surfacePermissionsIfNeeded() {
        guard !Permission.missingRequired.isEmpty,
              OnboardingPolicy.whenPermissionMissing(dismissed: settings.onboardingDismissed),
              permissionsWindow?.isShowing != true else { return }
        menuOpenPermissions()
    }

    private func refreshMenuStatics() {
        status.setEnabled(settings.dictationEnabled)
        status.setHasLastDictation(lastDictation != nil)
        updateClaudeLine()
        updateLastLine()
    }

    /// Shows a message for a while, then returns to the computed state (unless a dictation started).
    /// With `onScreen` the same text also appears in the floating indicator (dictation outcomes).
    private func flash(_ state: AppState, seconds: Double, onScreen: Bool = false) {
        status.set(state: state)
        if onScreen && settings.indicatorEnabled {
            if case .error = state { hud.show(.message(state.text, isError: true), for: seconds) }
            else { hud.show(.message(state.text, isError: false), for: min(seconds, 3)) }
        }
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy else { return }
                self.applyState()
            }
        }
    }

    // MARK: Key handling

    private var lastWrongKeyHint: Date?

    /// Another push-to-talk key was held alone: say which key Lavalier listens for, instead of doing nothing.
    private func otherKeyHeld(_ other: HotkeyChoice) {
        Log.dictation.notice("held \(other.rawValue, privacy: .public) alone, but the shortcuts are \(self.settings.hotkeys.spokenList, privacy: .public)")
        guard !busy, settings.dictationEnabled else { return }
        if let last = lastWrongKeyHint, Date().timeIntervalSince(last) < 120 { return }
        lastWrongKeyHint = Date()
        hud.show(.message("Lavalier listens for \(settings.hotkeys.spokenList), not \(other.label). Change this in Settings > Shortcuts.", isError: false), for: 5)
    }

    private func handle(_ transition: HotkeyTransition) {
        switch transition {
        case .pressed: beginDictation()
        case .released: endDictation()
        }
    }

    private func beginDictation() {
        guard settings.dictationEnabled, !busy else { return }
        guard reachability.isOnline else {
            flash(.error(DictationError.offline.userMessage), seconds: 4, onScreen: true)
            return
        }
        guard store.has(.elevenLabs) else {
            flash(.error(DictationError.missingKey(.elevenLabs).userMessage), seconds: 5, onScreen: true)
            return
        }
        if Permission.microphone.status == .notDetermined {
            // First use: let macOS ask. The dictation starts on the next key press.
            Log.permissions.notice("microphone not determined; asking macOS")
            Permission.microphone.request { }
            flash(.warning("Allow the microphone, then hold the key again."), seconds: 5, onScreen: true)
            return
        }
        guard Permission.microphone.status == .granted else {
            flash(.error(DictationError.permissionMissing("Microphone").userMessage), seconds: 5, onScreen: true)
            surfacePermissionsIfNeeded()
            return
        }
        let capture = AudioCapture()
        let stream: AsyncStream<Data>
        let micStarted = Date()
        holdStartedAt = micStarted
        do {
            stream = try capture.start()
        } catch let e as DictationError {
            Log.dictation.error("capture failed: \(e.userMessage, privacy: .public)")
            flash(.error(e.userMessage), seconds: 5, onScreen: true)
            return
        } catch {
            Log.dictation.error("capture failed: \(error.localizedDescription, privacy: .public)")
            flash(.error(DictationError.audio(error.localizedDescription).userMessage), seconds: 5, onScreen: true)
            return
        }
        self.capture = capture
        busy = true
        resetTimer?.invalidate()
        status.set(state: .listening)
        if settings.soundCuesEnabled { startSound?.play() }
        if settings.indicatorEnabled { hud.show(.listening(partial: nil)) }
        // Bluetooth headsets (AirPods) switch to their call mode when the microphone opens, which can take
        // most of a second; the key release is only seen after that. Logged so short dictations can be explained.
        let micMs = Date().timeIntervalSince(micStarted) * 1000
        let input = AVCaptureDevice.default(for: .audio)?.localizedName ?? "?"
        Log.dictation.notice("key down: listening (microphone started in \(micMs, format: .fixed(precision: 0), privacy: .public) ms, input \(input, privacy: .public))")
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: DictationController.maximumHoldSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endDictation() }
        }

        // The microphone stream is read once, into a buffer that keeps filling until the key is released,
        // and forwarded to the pipeline. If the first attempt fails on a transient error, the whole buffer
        // is replayed once after the release, so nothing said after the failure is lost.
        let buffer = ChunkBuffer()
        let forward = ForwardBox()
        Task.detached {
            for await chunk in stream {
                buffer.append(chunk)
                forward.yield(chunk)
            }
            buffer.finish()
            forward.finish()
        }
        let live = AsyncStream<Data> { continuation in forward.attach(continuation) }
        let pipeline = self.pipeline
        // Warm the Claude connection while the user is still speaking.
        Task.detached { await pipeline.prewarm() }
        let onPartial: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in self?.hud.update(partial: text) }
        }
        currentTask = Task { [weak self] in
            var outcome: DictationOutcome?
            var failure: DictationError?
            var retried = false
            do {
                outcome = try await pipeline.run(audio: live, onPartial: onPartial)
            } catch let e as DictationError {
                if e.isTransient || e == .connectTimeout {
                    retried = true
                    await buffer.waitUntilFinished()
                    do {
                        outcome = try await pipeline.run(audio: AudioChunking.stream(buffer.joined(), paced: false), onPartial: onPartial)
                    } catch let e2 as DictationError { failure = e2 } catch { failure = .network(error.localizedDescription) }
                } else {
                    failure = e
                }
            } catch {
                failure = .network(error.localizedDescription)
            }
            if Task.isCancelled { return }
            await self?.finish(outcome: outcome, failure: failure, retried: retried)
        }
    }

    private func endDictation() {
        guard busy, let capture else { return }
        holdTimer?.invalidate()
        capture.stop()
        Log.dictation.notice("microphone: \(capture.statsDescription, privacy: .public)")
        self.capture = nil
        status.set(state: .processing)
        if settings.soundCuesEnabled { stopSound?.play() }
        if settings.indicatorEnabled { hud.show(.processing) }
        Log.dictation.notice("key up: transcribing")
        processingTimer?.invalidate()
        processingDeadline = DictationLimits.processingDeadline(heldSeconds: Date().timeIntervalSince(holdStartedAt))
        processingTimer = Timer.scheduledTimer(withTimeInterval: processingDeadline, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.abandon() }
        }
    }

    /// The processing deadline passed: give up on this dictation so the next one can start.
    private func abandon() {
        guard busy else { return }
        currentTask?.cancel()
        currentTask = nil
        capture?.stop()
        capture = nil
        busy = false
        Log.dictation.error("abandoned after \(self.processingDeadline, format: .fixed(precision: 0), privacy: .public) s")
        flash(.error("That dictation did not finish in time and was abandoned. Try again."), seconds: 6, onScreen: true)
        if applyPending { applyState() }
    }

    private func finish(outcome: DictationOutcome?, failure: DictationError?, retried: Bool) async {
        processingTimer?.invalidate()
        holdTimer?.invalidate()
        capture?.stop()
        capture = nil
        var shownMessage = false
        defer {
            busy = false
            if applyPending { applyState() } else if !shownMessage { applyState() }
        }
        if let failure {
            Log.dictation.error("failed: \(failure.userMessage, privacy: .public)\(retried ? " [retried]" : "", privacy: .public)")
            flash(.error(failure.userMessage), seconds: 6, onScreen: true)
            shownMessage = true
            return
        }
        guard let outcome else { hud.hide(); return }
        var insertMs: Double?
        var insertPath: String?
        var insertNote: String?
        var insertApp: String?
        var insertFailed = false
        if outcome.finalText.isEmpty {
            flash(.warning("No speech was heard."), seconds: 3, onScreen: true)
            shownMessage = true
        } else {
            lastDictation = outcome.finalText
            status.setHasLastDictation(true)
            do {
                let result = try await inserter.insert(outcome.finalText)
                insertMs = result.milliseconds
                insertPath = result.path.rawValue
                insertNote = result.note
                insertApp = result.app
                hud.hide()
            } catch let e as DictationError {
                insertFailed = true
                flash(.error(e.userMessage), seconds: 8, onScreen: true)
                shownMessage = true
                if case .permissionMissing = e { surfacePermissionsIfNeeded() }
            } catch {
                insertFailed = true
                flash(.error(DictationError.insertionFailed(error.localizedDescription).userMessage), seconds: 8, onScreen: true)
                shownMessage = true
            }
        }
        usage.record(usage: outcome.billedUsageEstimate, audioSeconds: outcome.audioSeconds, sttMs: outcome.sttMs,
                     claudeMs: outcome.claudeMs, totalMs: outcome.totalMs + (insertMs ?? 0))
        try? usage.save()
        updateClaudeLine()
        updateLastLine()
        var pathNote = insertPath ?? (insertFailed ? "failed" : "none")
        if let n = insertNote, !n.isEmpty { pathNote += " (\(n))" }
        if retried { pathNote += " [retried]" }
        Log.dictation.notice("done: audio \(outcome.audioSeconds, format: .fixed(precision: 1), privacy: .public) s, stt \(outcome.sttMs, format: .fixed(precision: 0), privacy: .public) ms, claude \(outcome.claudeMs ?? 0, format: .fixed(precision: 0), privacy: .public) ms, total \(outcome.totalMs, format: .fixed(precision: 0), privacy: .public) ms, insert \(insertMs ?? 0, format: .fixed(precision: 0), privacy: .public) ms via \(pathNote, privacy: .public) into \(insertApp ?? "?", privacy: .public), \(outcome.finalText.count, privacy: .public) characters")
        if settings.timingLogEnabled {
            TimingLog.append(outcome, insertMs: insertMs, insertPath: pathNote, app: insertApp)
        }
        if !insertFailed, let cleanupError = outcome.cleanupError {
            flash(.warning("Inserted as heard. " + cleanupError.userMessage), seconds: 4, onScreen: true)
            shownMessage = true
        } else if !insertFailed, let note = insertNote, !note.isEmpty, !note.hasPrefix("paste only"), !outcome.finalText.isEmpty,
                  note.contains("clipboard") {
            flash(.warning(note.prefix(1).uppercased() + note.dropFirst() + "."), seconds: 4)
            shownMessage = true
        }
        refreshSubscription(force: false)
    }

    // MARK: Usage lines

    private func updateClaudeLine() { status.setClaude(UsageMenuText.claudeLine(usage)) }

    private func updateLastLine() { status.setLast(UsageMenuText.lastLine(usage)) }

    private func refreshSubscription(force: Bool) {
        if !force, let at = subscriptionFetchedAt, Date().timeIntervalSince(at) < 60 { return }
        guard store.has(.elevenLabs) else {
            status.setCredits("ElevenLabs: key missing", low: false)
            return
        }
        subscriptionFetchedAt = Date()
        let store = self.store
        Task { @MainActor in
            do {
                let key = try KeychainKeyProvider(store: store).key(for: .elevenLabs)
                let sub = try await ElevenLabsAccount.fetchSubscription(apiKey: key)
                subscription = sub
                let (text, low) = UsageMenuText.creditsLine(sub)
                status.setCredits(text, low: low)
            } catch let e as DictationError {
                status.setCredits("ElevenLabs: \(e.userMessage)", low: false)
            } catch {
                status.setCredits("ElevenLabs: \(error.localizedDescription)", low: false)
            }
        }
    }

    // MARK: Menu

    func menuToggleEnabled() {
        settings.dictationEnabled.toggle()
        status.setEnabled(settings.dictationEnabled)
        if busy && !settings.dictationEnabled { endDictation() }
        applyState()
    }

    func menuCopyLastDictation() {
        guard let text = lastDictation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func menuRefreshUsage() {
        refreshSubscription(force: false)
    }

    func menuOpenSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, store: store)
            settingsWindow?.onSettingsChanged = { [weak self] in
                guard let self else { return }
                self.pipeline = DictationController.makePipeline(settings: self.settings, store: self.store)
                self.status.glyphStyle = self.settings.menuBarGlyph
                self.applyState()
                self.refreshSubscription(force: true)
            }
            // While Settings waits for a new shortcut, the shortcuts must neither dictate nor swallow the press.
            settingsWindow?.onRecordingChanged = { [weak self] recording in
                self?.hotkey.isSuspended = recording
            }
        }
        settingsWindow?.show()
    }

    func menuOpenPermissions() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController()
            // A refresh only re-evaluates the state; it never counts as "the user closed the window".
            permissionsWindow?.onChange = { [weak self] in
                guard let self else { return }
                self.settings.onboardingDismissed = OnboardingPolicy.afterRefresh(dismissed: self.settings.onboardingDismissed)
                self.applyState()
            }
            permissionsWindow?.onClose = { [weak self] in
                guard let self else { return }
                self.settings.onboardingDismissed = OnboardingPolicy.afterClose()
                self.logPermissions("permissions window closed")
                self.applyState()
            }
        }
        Log.permissions.notice("permissions window shown")
        permissionsWindow?.show()
    }

    func menuQuit() {
        shutdown()
        NSApp.terminate(nil)
    }
}

/// Collects the microphone chunks for one dictation and reports when the stream has ended.
final class ChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func append(_ d: Data) { lock.lock(); chunks.append(d); lock.unlock() }

    func finish() {
        lock.lock()
        finished = true
        let w = waiters
        waiters.removeAll()
        lock.unlock()
        for c in w { c.resume() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    func joined() -> Data { lock.lock(); defer { lock.unlock() }; return chunks.reduce(into: Data()) { $0.append($1) } }
}

/// Forwards chunks to a stream continuation that may be attached later or dropped by its consumer.
final class ForwardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var pending: [Data] = []
    private var finished = false

    func attach(_ c: AsyncStream<Data>.Continuation) {
        lock.lock()
        continuation = c
        let p = pending; pending.removeAll()
        let f = finished
        lock.unlock()
        for d in p { c.yield(d) }
        if f { c.finish() }
        c.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuation = nil; self.lock.unlock()
        }
    }

    func yield(_ d: Data) {
        lock.lock()
        if let c = continuation { lock.unlock(); c.yield(d) } else { pending.append(d); lock.unlock() }
    }

    func finish() {
        lock.lock()
        finished = true
        let c = continuation
        lock.unlock()
        c?.finish()
    }
}
