import AppKit
import ServiceManagement
import LavalierCore

// Maintenance entry points that run without the UI. Used by the tests and from Terminal.
let arguments = CommandLine.arguments
if arguments.contains("--import-keys-from-environment") {
    // Stores ELEVENLABS_API_KEY and ANTHROPIC_API_KEY from the environment in this app's Keychain items. Values are never printed.
    let store = KeychainStore()
    let env = ProcessInfo.processInfo.environment
    for (account, name) in [(KeyAccount.elevenLabs, "ELEVENLABS_API_KEY"), (KeyAccount.anthropic, "ANTHROPIC_API_KEY")] {
        if let value = env[name], !value.isEmpty {
            do {
                try store.set(value, for: account)
                print("stored \(account.rawValue) key in Keychain service \"\(KeychainStore.appService)\"")
            } catch {
                print("FAILED to store \(account.rawValue): \(error)")
                exit(1)
            }
        } else {
            print("\(name) is not set in the environment; nothing stored for \(account.rawValue)")
        }
    }
    exit(0)
}
if arguments.contains("--test-connection") {
    // Same checks as Settings > Keys > Test Connection, using the Keychain, without the window.
    let provider = KeychainKeyProvider()
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        do {
            let sub = try await ElevenLabsAccount.fetchSubscription(apiKey: try provider.key(for: .elevenLabs))
            print("ElevenLabs OK: \(sub.tier) plan, \(sub.creditsUsed) of \(sub.creditLimit) credits used")
        } catch let e as DictationError { print("ElevenLabs: \(e.userMessage)"); code = 1 } catch { print("ElevenLabs: \(error)"); code = 1 }
        do {
            try await ClaudeClient(apiKey: try provider.key(for: .anthropic)).testConnection()
            print("Anthropic OK: key accepted")
        } catch let e as DictationError { print("Anthropic: \(e.userMessage)"); code = 1 } catch { print("Anthropic: \(error)"); code = 1 }
        semaphore.signal()
    }
    semaphore.wait()
    exit(code)
}
if arguments.contains("--probe-hotkey") {
    // Reports which key-monitoring mechanism macOS lets this app use right now.
    let ok: Bool = MainActor.assumeIsolated {
        let shortcuts = AppSettings.shared.hotkeys
        let monitor = HotkeyMonitor(bindings: shortcuts)
        let started = monitor.start()
        print("shortcuts \(shortcuts.spokenList): \(started ? "monitoring via \(monitor.mechanismDescription ?? "?")" : "no mechanism available (needs Accessibility or Input Monitoring)")")
        monitor.stop()
        return started
    }
    print("Accessibility: \(Permission.accessibility.status.label); Input Monitoring: \(Permission.inputMonitoring.status.label)")
    exit(ok ? 0 : 1)
}
if let i = arguments.firstIndex(of: "--watch-hotkeys") {
    // Watches the shortcuts for N seconds (default 20) and prints each press and release, without
    // dictating. --bindings '<JSON list>' overrides the saved list, e.g.
    // '[{"key":{"code":105,"modifiers":0}},{"mouse":{"button":5}},{"modifier":{"key":"leftShift"}}]'.
    let seconds = (i + 1 < arguments.count ? Double(arguments[i + 1]) : nil) ?? 20
    var shortcuts = AppSettings.shared.hotkeys
    if let j = arguments.firstIndex(of: "--bindings"), j + 1 < arguments.count {
        guard let list = try? JSONDecoder().decode([HotkeyBinding].self, from: Data(arguments[j + 1].utf8)) else {
            print("could not read --bindings"); exit(2)
        }
        shortcuts = list
    }
    MainActor.assumeIsolated {
        let monitor = HotkeyMonitor(bindings: shortcuts)
        let start = Date()
        monitor.onTransition = { t in
            print(String(format: "%.3f s %@", Date().timeIntervalSince(start), t == .pressed ? "pressed (dictation would start)" : "released (dictation would end)"))
            fflush(stdout)
        }
        let started = monitor.start()
        print("watching \(shortcuts.spokenList) for \(Int(seconds)) s: \(started ? monitor.mechanismDescription ?? "?" : "no mechanism available")")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { monitor.stop(); exit(started ? 0 : 1) }
    }
    RunLoop.main.run()
}
if arguments.contains("--usage-report") {
    // Prints the three usage lines exactly as the menu composes them, from the Keychain and usage.json.
    // --simulate-remaining N pretends N credits remain, to show the low-credit state.
    let simulated = arguments.firstIndex(of: "--simulate-remaining").flatMap { i in i + 1 < arguments.count ? Int(arguments[i + 1]) : nil }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        print(UsageMenuText.claudeLine(UsageTally.load()))
        print(UsageMenuText.lastLine(UsageTally.load()))
        do {
            let key = try KeychainKeyProvider().key(for: .elevenLabs)
            var sub = try await ElevenLabsAccount.fetchSubscription(apiKey: key)
            if let n = simulated {
                sub = ElevenLabsSubscription(tier: sub.tier, creditsUsed: sub.creditLimit - n, creditLimit: sub.creditLimit, nextReset: sub.nextReset, status: sub.status)
            }
            let (text, low) = UsageMenuText.creditsLine(sub)
            print(text + (low ? "   [shown in warning colour]" : ""))
        } catch let e as DictationError { print("ElevenLabs: \(e.userMessage)") } catch { print("ElevenLabs: \(error)") }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if let i = arguments.firstIndex(of: "--login-item"), i + 1 < arguments.count {
    // register | unregister | status. Same calls as the Settings checkbox.
    func label(_ s: SMAppService.Status) -> String {
        switch s { case .enabled: return "enabled"; case .requiresApproval: return "requires approval"; case .notFound: return "not registered"; default: return "not registered" }
    }
    do {
        switch arguments[i + 1] {
        case "register": try SMAppService.mainApp.register()
        case "unregister": try SMAppService.mainApp.unregister()
        default: break
        }
        print("login item: \(label(SMAppService.mainApp.status))")
        exit(0)
    } catch {
        print("login item: FAILED \(error.localizedDescription) (status \(label(SMAppService.mainApp.status)))")
        exit(1)
    }
}
if let i = arguments.firstIndex(of: "--render-glyphs"), i + 1 < arguments.count {
    // Writes every menu-bar icon option in every state as PNG (4 px per point) for review.
    let dir = URL(fileURLWithPath: arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var written = 0
    for style in MenuBarGlyphStyle.allCases {
        for state in MenuBarGlyphState.allCases {
            if let png = MenuBarGlyph.png(style: style, state: state) {
                try? png.write(to: dir.appendingPathComponent("\(style.rawValue)_\(state.rawValue).png"))
                written += 1
            }
        }
    }
    print("wrote \(written) glyph PNGs to \(dir.path)")
    exit(0)
}
if arguments.contains("--print-permissions") {
    for p in Permission.allCases { print("\(p.title): \(p.status.label)") }
    let store = KeychainStore()
    print("Keychain: elevenlabs \(store.has(.elevenLabs) ? "present" : "missing"), anthropic \(store.has(.anthropic) ? "present" : "missing")")
    print("Note: run from a terminal, the three permission lines reflect the terminal host's grants, not the app's.")
    print("The app's own view is its Permissions window, or: log show --predicate 'subsystem == \"com.davidfinnegan.lavalier\"' --last 10m")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
