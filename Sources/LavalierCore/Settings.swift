import Foundation

/// Non-secret preferences. Keys never go here.
public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings(defaults: .standard)

    private let defaults: UserDefaults
    private enum Key {
        static let hotkey = "hotkey"
        static let cleanupEnabled = "cleanupEnabled"
        static let timingLogEnabled = "timingLogEnabled"
        static let sendKeyterms = "sendKeyterms"
        static let dictationEnabled = "dictationEnabled"
        static let onboardingDismissed = "onboardingDismissed"
        static let soundCuesEnabled = "soundCuesEnabled"
        static let indicatorEnabled = "indicatorEnabled"
        static let menuBarGlyph = "menuBarGlyph"
        static let hotkeyConflictMigration = "hotkeyConflictMigrationDone"
        static let hotkeys = "hotkeys"
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var hotkey: HotkeyChoice {
        get { defaults.string(forKey: Key.hotkey).flatMap(HotkeyChoice.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    /// All push-to-talk shortcuts. Until a list is saved in Settings, this is the single `hotkey`
    /// above (so the default stays whatever `HotkeyChoice.default` is; not changed here). An empty or unreadable
    /// saved list also falls back to it, so there is always at least one shortcut.
    public var hotkeys: [HotkeyBinding] {
        get {
            if let data = defaults.data(forKey: Key.hotkeys),
               let list = try? JSONDecoder().decode([HotkeyBinding].self, from: data), !list.isEmpty {
                return list
            }
            return [HotkeyBinding(hotkey)]
        }
        set {
            var unique: [HotkeyBinding] = []
            for b in newValue where !unique.contains(b) { unique.append(b) }
            if unique.isEmpty { defaults.removeObject(forKey: Key.hotkeys); return }
            if let data = try? JSONEncoder().encode(unique) { defaults.set(data, forKey: Key.hotkeys) }
        }
    }

    public var cleanupEnabled: Bool {
        get { defaults.object(forKey: Key.cleanupEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    public var timingLogEnabled: Bool {
        get { defaults.bool(forKey: Key.timingLogEnabled) }
        set { defaults.set(newValue, forKey: Key.timingLogEnabled) }
    }

    public var sendKeyterms: Bool {
        get { defaults.bool(forKey: Key.sendKeyterms) }
        set { defaults.set(newValue, forKey: Key.sendKeyterms) }
    }

    public var dictationEnabled: Bool {
        get { defaults.object(forKey: Key.dictationEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.dictationEnabled) }
    }

    /// True once the user has closed the Permissions window since the last launch. See `OnboardingPolicy`.
    public var onboardingDismissed: Bool {
        get { defaults.bool(forKey: Key.onboardingDismissed) }
        set { defaults.set(newValue, forKey: Key.onboardingDismissed) }
    }

    /// Short sound when listening starts and when it stops.
    public var soundCuesEnabled: Bool {
        get { defaults.object(forKey: Key.soundCuesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundCuesEnabled) }
    }

    /// Floating on-screen indicator with the live transcript while the key is held.
    public var indicatorEnabled: Bool {
        get { defaults.object(forKey: Key.indicatorEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.indicatorEnabled) }
    }

    /// Which menu-bar icon to draw.
    public var menuBarGlyph: MenuBarGlyphStyle {
        get { defaults.string(forKey: Key.menuBarGlyph).flatMap(MenuBarGlyphStyle.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarGlyph) }
    }

    /// One-time move off Right Option and Right Command, for installs from before Right Control became the
    /// default (both keys often have other uses). A new install starts on Right Control and is never moved.
    /// Runs once; afterwards the user's choice is respected whatever it is. Returns the key that was replaced,
    /// so the app can say so on screen.
    @discardableResult
    public func migrateHotkeyAwayFromConflicts() -> HotkeyChoice? {
        guard !defaults.bool(forKey: Key.hotkeyConflictMigration) else { return nil }
        defaults.set(true, forKey: Key.hotkeyConflictMigration)
        let current = hotkey
        guard HotkeyChoice.conflicting.contains(current) else { return nil }
        hotkey = .default
        return current
    }
}

/// When the Permissions window shows itself and what the `onboardingDismissed` flag means.
/// The bug this replaces: the flag was set on every two-second status refresh, so the window never showed
/// again after it had been displayed once anywhere.
public enum OnboardingPolicy {
    public struct LaunchDecision: Equatable, Sendable {
        public let showWindow: Bool
        public let dismissed: Bool
    }

    /// At launch: a missing required permission always shows the window, and clears the flag so that only a
    /// later close by the user sets it again. With nothing missing the window stays hidden and the flag is kept.
    public static func atLaunch(missingRequired: Bool, dismissed: Bool) -> LaunchDecision {
        missingRequired ? LaunchDecision(showWindow: true, dismissed: false) : LaunchDecision(showWindow: false, dismissed: dismissed)
    }

    /// A status refresh while the window is open never changes the flag.
    public static func afterRefresh(dismissed: Bool) -> Bool { dismissed }

    /// Closing the window is the only thing that sets the flag.
    public static func afterClose() -> Bool { true }

    /// While running: a required permission has gone missing (revoked, or never granted). Show the window
    /// unless the user has already closed it since launch.
    public static func whenPermissionMissing(dismissed: Bool) -> Bool { !dismissed }
}
