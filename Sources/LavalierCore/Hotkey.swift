import Foundation
import CoreGraphics

/// Push-to-talk keys the user can choose. All are modifier keys, so they arrive as flagsChanged events.
public enum HotkeyChoice: String, CaseIterable, Codable, Sendable {
    case rightControl
    case fn
    case rightOption
    case rightCommand

    /// Right Control: a modifier that few other tools react to. Right Option and Right Command often have other
    /// uses (a double-tap shortcut in another app, another dictation tool).
    public static let `default`: HotkeyChoice = .rightControl

    /// Keys known to collide with other tools; `AppSettings.migrateHotkeyAwayFromConflicts` moves off them once.
    public static let conflicting: Set<HotkeyChoice> = [.rightOption, .rightCommand]

    /// Virtual key code reported in the flagsChanged event.
    public var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    /// Device-specific bit in CGEventFlags.rawValue that tells right from left (NX_DEVICER*KEYMASK),
    /// or the fn flag. Checked on the event flags to decide pressed versus released.
    public var deviceFlagBit: UInt64 {
        switch self {
        case .rightOption: return 0x0000_0040
        case .rightCommand: return 0x0000_0010
        case .rightControl: return 0x0000_2000
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    public var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "fn / Globe"
        }
    }

    /// Shown under the Settings popup. Nil when there is nothing to warn about.
    public var note: String? {
        switch self {
        case .fn:
            return "Set System Settings > Keyboard > \"Press 🌐 key to\" to \"Do Nothing\" first, or macOS will act on the key itself."
        case .rightOption:
            return "If another app uses a double-tap of Option as its shortcut, it can open by accident while you dictate."
        case .rightCommand:
            return "If another dictation app uses this key, both will start at once."
        case .rightControl:
            // Hotkey bug of 2 Nov 2026: Apple's MacBook keyboards have Control on the left only, and the left
            // key is deliberately ignored, so pressing "Control" on a MacBook did nothing.
            return "MacBook keyboards have no Right Control key, and the left Control key does not count for this one. Use it only with an external keyboard that has a Right Control key, or add Left Control as its own shortcut."
        }
    }
}

public enum HotkeyTransition: Equatable, Sendable {
    case pressed
    case released
}

/// Turns a stream of flagsChanged events into pressed/released transitions for one chosen key.
public struct HotkeyTracker: Sendable {
    public let choice: HotkeyChoice
    public private(set) var isDown = false

    public init(choice: HotkeyChoice) { self.choice = choice }

    public mutating func handle(keyCode: Int64, flagsRaw: UInt64) -> HotkeyTransition? {
        guard keyCode == choice.keyCode else { return nil }
        let down = (flagsRaw & choice.deviceFlagBit) != 0
        if down && !isDown { isDown = true; return .pressed }
        if !down && isDown { isDown = false; return .released }
        return nil
    }

    public mutating func reset() { isDown = false }
}

/// Notices when one of the *other* push-to-talk keys is held on its own, as if to dictate (hotkey bug,
/// 2 Nov 2026: Settings said Right Control while the user held Right Command, and the app did nothing, silently).
/// Only modifier events are seen, never typed characters, so Command+Tab held with Right Command can also
/// trigger it; the caller rate-limits the on-screen hint.
public struct WrongKeyDetector: Sendable {
    public private(set) var chosen: HotkeyChoice
    /// Every key of the list that is itself a push-to-talk shortcut (several shortcuts at once).
    public private(set) var bound: Set<HotkeyChoice>
    public static let minimumHoldSeconds = 0.8
    private var held: (key: HotkeyChoice, since: Double)?

    public init(chosen: HotkeyChoice) { self.chosen = chosen; bound = [chosen] }

    /// For a list of shortcuts: only the four listed keys that are not shortcuts produce a hint.
    public init(bindings: [HotkeyBinding]) {
        chosen = .default
        bound = []
        update(bindings: bindings)
    }

    public mutating func update(chosen: HotkeyChoice) { self.chosen = chosen; bound = [chosen]; held = nil }

    public mutating func update(bindings: [HotkeyBinding]) {
        bound = Set(bindings.compactMap { if case .modifier(let k) = $0 { return k.choice }; return nil })
        chosen = bound.first ?? .default
        held = nil
    }

    /// Returns the key when an other push-to-talk key was released after being held alone long enough.
    public mutating func handle(keyCode: Int64, flagsRaw: UInt64, at seconds: Double) -> HotkeyChoice? {
        guard let key = HotkeyChoice.allCases.first(where: { !bound.contains($0) && $0.keyCode == keyCode }) else {
            held = nil
            return nil
        }
        if (flagsRaw & key.deviceFlagBit) != 0 {
            // Pressed: only counts if no other modifier is held with it.
            held = (flagsRaw & HotkeyChoice.modifierClassMask) == key.classMask ? (key, seconds) : nil
            return nil
        }
        defer { held = nil }
        if let h = held, h.key == key, seconds - h.since >= Self.minimumHoldSeconds { return key }
        return nil
    }
}

extension HotkeyChoice {
    /// Device-independent modifier flag for this key (Command, Option, Control, fn).
    public var classMask: UInt64 {
        switch self {
        case .rightCommand: return CGEventFlags.maskCommand.rawValue
        case .rightOption: return CGEventFlags.maskAlternate.rawValue
        case .rightControl: return CGEventFlags.maskControl.rawValue
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    static let modifierClassMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskShift.rawValue
}
