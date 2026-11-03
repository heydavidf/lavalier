import AppKit
import LavalierCore

enum AppState: Equatable {
    case idle
    case listening
    case processing
    case disabled
    case needsSetup(String)
    case error(String)
    case warning(String)

    var glyphState: MenuBarGlyphState {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .disabled: return .disabled
        case .needsSetup, .error, .warning: return .attention
        }
    }

    var text: String {
        switch self {
        case .idle: return "Ready. Hold the key to dictate."
        case .listening: return "Listening…"
        case .processing: return "Transcribing…"
        case .disabled: return "Dictation is off."
        case .needsSetup(let m), .error(let m), .warning(let m): return m
        }
    }
}

@MainActor
protocol StatusMenuDelegate: AnyObject {
    func menuToggleEnabled()
    func menuCopyLastDictation()
    func menuRefreshUsage()
    func menuOpenSettings()
    func menuOpenPermissions()
    func menuQuit()
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    weak var delegate: StatusMenuDelegate?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hotkeyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "ElevenLabs: not checked yet", action: nil, keyEquivalent: "")
    private let claudeItem = NSMenuItem(title: "Claude this month: 0 calls", action: nil, keyEquivalent: "")
    private let lastItem = NSMenuItem(title: "Last dictation: none yet", action: nil, keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let copyItem = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")

    private(set) var state: AppState = .idle
    /// Which icon family to draw; changing it redraws the current state.
    var glyphStyle: MenuBarGlyphStyle = .default {
        didSet { if glyphStyle != oldValue { set(state: state) } }
    }

    init(glyphStyle: MenuBarGlyphStyle = .default) {
        self.glyphStyle = glyphStyle
        super.init()
        menu.delegate = self
        for i in [stateItem, hotkeyItem, creditsItem, claudeItem, lastItem] { i.isEnabled = false }
        menu.addItem(stateItem)
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())
        menu.addItem(creditsItem)
        menu.addItem(claudeItem)
        menu.addItem(lastItem)
        menu.addItem(.separator())
        enabledItem.target = self
        menu.addItem(enabledItem)
        copyItem.target = self
        copyItem.isEnabled = false
        menu.addItem(copyItem)
        let refresh = NSMenuItem(title: "Refresh Usage", action: #selector(refreshUsage), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let perms = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Lavalier", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        set(state: .idle)
        Log.app.notice("status item created: \(self.placementDescription, privacy: .public)")
    }

    /// Where the status item ended up, for the log and the launch cue. A status item that does
    /// not fit in the menu bar (MacBook notch, many icons) is created but its window lands off screen.
    var placementDescription: String {
        guard let window = item.button?.window else { return "no window yet" }
        let frame = window.frame
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        return String(format: "frame x=%.0f y=%.0f w=%.0f h=%.0f, on a screen: %@, visible flag: %@",
                      frame.origin.x, frame.origin.y, frame.width, frame.height, onScreen ? "yes" : "no", item.isVisible ? "yes" : "no")
    }

    /// True when the item's window intersects no screen, which is how a hidden (overflowed) item looks.
    var looksHidden: Bool {
        guard let frame = item.button?.window?.frame else { return true }
        return !NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    func set(state: AppState) {
        self.state = state
        let image = MenuBarGlyph.image(style: glyphStyle, state: state.glyphState)
        image.accessibilityDescription = state.text
        item.button?.image = image
        item.button?.toolTip = "Lavalier: \(state.text)"
        stateItem.title = state.text
        switch state {
        case .listening: item.button?.contentTintColor = .systemRed
        case .error: item.button?.contentTintColor = .systemRed
        case .warning, .needsSetup: item.button?.contentTintColor = .systemOrange
        default: item.button?.contentTintColor = nil
        }
    }

    func setHotkey(_ choice: HotkeyChoice, monitorKind: String?) {
        hotkeyItem.title = "Hold \(choice.label)" + (monitorKind.map { " · \($0)" } ?? "")
    }

    /// Several shortcuts: "Hold Right Control or Middle mouse button · event tap".
    func setHotkey(label: String, monitorKind: String?) {
        hotkeyItem.title = "Hold \(label)" + (monitorKind.map { " · \($0)" } ?? "")
    }

    func setEnabled(_ enabled: Bool) { enabledItem.state = enabled ? .on : .off }
    func setHasLastDictation(_ has: Bool) { copyItem.isEnabled = has }

    func setCredits(_ text: String, low: Bool) {
        creditsItem.title = text
        creditsItem.attributedTitle = low
            ? NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.systemOrange])
            : nil
    }

    func setClaude(_ text: String) { claudeItem.title = text }
    func setLast(_ text: String) { lastItem.title = text }

    @objc private func toggleEnabled() { delegate?.menuToggleEnabled() }
    @objc private func copyLast() { delegate?.menuCopyLastDictation() }
    @objc private func refreshUsage() { delegate?.menuRefreshUsage() }
    @objc private func openSettings() { delegate?.menuOpenSettings() }
    @objc private func openPermissions() { delegate?.menuOpenPermissions() }
    @objc private func quit() { delegate?.menuQuit() }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in delegate?.menuRefreshUsage() }
    }
}
