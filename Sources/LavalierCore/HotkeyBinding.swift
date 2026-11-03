import Foundation
import CoreGraphics

// Configurable push-to-talk shortcuts (3 Nov 2026). The user can set several at once: a modifier key
// held on its own, a keyboard key (optionally with modifiers), or an extra mouse button. Holding any one of
// them starts dictation; releasing ends it. The single-key `HotkeyChoice` setting stays as the fallback when no
// list has been saved, so the default (Right Control) is not changed here.

/// A modifier key that can be held on its own. Left and right are told apart by the device-specific flag bits.
public enum ModifierKey: String, CaseIterable, Codable, Sendable {
    case rightControl, leftControl, rightOption, leftOption, rightCommand, leftCommand, rightShift, leftShift, fn

    public var keyCode: Int64 {
        switch self {
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftShift: return 56
        case .rightShift: return 60
        case .fn: return 63
        }
    }

    /// NX_DEVICE*KEYMASK bit in the event flags, or the fn flag.
    public var deviceFlagBit: UInt64 {
        switch self {
        case .leftControl: return 0x0000_0001
        case .leftShift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    public var label: String {
        switch self {
        case .leftControl: return "Left Control (⌃)"
        case .rightControl: return "Right Control (⌃)"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftShift: return "Left Shift (⇧)"
        case .rightShift: return "Right Shift (⇧)"
        case .fn: return "fn / Globe"
        }
    }

    /// Device-independent flag for this key's kind (Control, Option, Command, Shift, fn).
    public var classMaskRaw: UInt64 {
        switch self {
        case .leftControl, .rightControl: return CGEventFlags.maskControl.rawValue
        case .leftOption, .rightOption: return CGEventFlags.maskAlternate.rawValue
        case .leftCommand, .rightCommand: return CGEventFlags.maskCommand.rawValue
        case .leftShift, .rightShift: return CGEventFlags.maskShift.rawValue
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    public init?(keyCode: Int64) {
        guard let k = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = k
    }

    /// The matching entry of the original four-key list, if any.
    public var choice: HotkeyChoice? {
        switch self {
        case .rightControl: return .rightControl
        case .rightOption: return .rightOption
        case .rightCommand: return .rightCommand
        case .fn: return .fn
        default: return nil
        }
    }
}

/// Device-independent modifiers that must be held with a keyboard key (for example Control+Option+Space).
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// From CGEventFlags / NSEvent.ModifierFlags raw values (same bit layout). fn and Caps Lock are ignored.
    public init(flagsRaw: UInt64) {
        var m: KeyModifiers = []
        if flagsRaw & CGEventFlags.maskControl.rawValue != 0 { m.insert(.control) }
        if flagsRaw & CGEventFlags.maskAlternate.rawValue != 0 { m.insert(.option) }
        if flagsRaw & CGEventFlags.maskShift.rawValue != 0 { m.insert(.shift) }
        if flagsRaw & CGEventFlags.maskCommand.rawValue != 0 { m.insert(.command) }
        self = m
    }

    /// Apple's order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// One push-to-talk shortcut.
public enum HotkeyBinding: Codable, Hashable, Sendable {
    /// A modifier key held on its own.
    case modifier(key: ModifierKey)
    /// A keyboard key (virtual key code) with exactly these modifiers held.
    case key(code: Int64, modifiers: KeyModifiers)
    /// A mouse button by CGEvent button number: 2 is the middle button, 3 and 4 are the side buttons.
    /// 0 (left) and 1 (right) are never accepted.
    case mouse(button: Int64)

    public init(_ choice: HotkeyChoice) {
        switch choice {
        case .rightControl: self = .modifier(key: .rightControl)
        case .rightOption: self = .modifier(key: .rightOption)
        case .rightCommand: self = .modifier(key: .rightCommand)
        case .fn: self = .modifier(key: .fn)
        }
    }

    public var isKeyboardKey: Bool { if case .key = self { return true }; return false }
    public var isMouse: Bool { if case .mouse = self { return true }; return false }

    /// Left and right click can never be a shortcut (the Mac would become unusable).
    public static func acceptsMouseButton(_ button: Int64) -> Bool { button >= 2 && button < 32 }

    public var label: String {
        switch self {
        case .modifier(let key): return key.label
        case .key(let code, let modifiers): return modifiers.symbols + KeyNames.name(for: code)
        case .mouse(let button):
            switch button {
            case 2: return "Middle mouse button"
            case 3: return "Mouse button 4 (side, often Back)"
            case 4: return "Mouse button 5 (side, often Forward)"
            default: return "Mouse button \(button + 1)"
            }
        }
    }

    /// Plain-language warning shown under the shortcut in Settings. Nil when there is nothing to say.
    public var note: String? {
        switch self {
        case .modifier(let key):
            if let choice = key.choice { return choice.note }
            return "This key is part of everyday shortcuts; every shortcut that uses it would also start dictation."
        case .key(let code, let modifiers):
            if modifiers.isEmpty || modifiers == .shift, KeyNames.typesCharacter(code) {
                return "This key normally types. While it is a shortcut, Lavalier keeps it for itself, so it no longer types in other apps."
            }
            if KeyNames.isFunctionKey(code) {
                return "On a MacBook keyboard the top row sends brightness and volume unless you hold fn, or turn on \"Use F1, F2, etc. keys as standard function keys\" in System Settings > Keyboard."
            }
            return nil
        case .mouse:
            return "Lavalier keeps this button for itself while it is a shortcut, so it no longer does its usual job (such as Back) in other apps."
        }
    }
}

/// English (ANSI) names for virtual key codes, for labels only.
public enum KeyNames {
    static let names: [Int64: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`", 10: "§",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /",
        78: "Keypad -", 81: "Keypad =", 76: "Keypad Enter", 71: "Clear",
    ]
    static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let nonTyping: Set<Int64> = [53, 123, 124, 125, 126, 115, 119, 116, 121, 114, 117, 71,
                                        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    public static func name(for code: Int64) -> String { names[code] ?? "Key \(code)" }
    public static func isFunctionKey(_ code: Int64) -> Bool { functionKeys.contains(code) }
    /// True for keys that put a character or a line break into text when pressed alone.
    public static func typesCharacter(_ code: Int64) -> Bool { !nonTyping.contains(code) }
}

extension Array where Element == HotkeyBinding {
    /// "Right Control or Mouse button 4 (side, often Back)": for the menu and on-screen hints.
    public var spokenList: String {
        if isEmpty { return "no shortcut" }
        if count == 1 { return self[0].label }
        return dropLast().map(\.label).joined(separator: ", ") + " or " + last!.label
    }
}

/// Decides, event by event, whether one of several shortcuts is held. Dictation runs while at least one is held:
/// `.pressed` when the first goes down, `.released` when the last comes up. Also says which events belong to a
/// keyboard or mouse shortcut, so the monitor can keep them from reaching other apps.
public struct HotkeyMatcher: Sendable {
    public private(set) var bindings: [HotkeyBinding]
    private var held: Set<HotkeyBinding> = []

    public init(bindings: [HotkeyBinding]) { self.bindings = bindings }

    public var isDown: Bool { !held.isEmpty }
    public var needsKeyEvents: Bool { bindings.contains { $0.isKeyboardKey } }
    public var needsMouseEvents: Bool { bindings.contains { $0.isMouse } }

    public struct Outcome: Equatable, Sendable {
        public var transition: HotkeyTransition?
        /// The event belongs to a shortcut; an active event tap should not pass it on.
        public var consume: Bool
        public static let ignored = Outcome(transition: nil, consume: false)
    }

    /// Replaces the shortcuts. Returns `.released` if something was held, so the caller is never left waiting.
    public mutating func update(bindings new: [HotkeyBinding]) -> HotkeyTransition? {
        guard new != bindings else { return nil }
        bindings = new
        return releaseAll()
    }

    public mutating func releaseAll() -> HotkeyTransition? {
        let wasDown = isDown
        held.removeAll()
        return wasDown ? .released : nil
    }

    private mutating func set(_ b: HotkeyBinding, down: Bool) -> HotkeyTransition? {
        let wasDown = isDown
        if down { held.insert(b) } else { held.remove(b) }
        if !wasDown && isDown { return .pressed }
        if wasDown && !isDown { return .released }
        return nil
    }

    /// A modifier key changed. Never consumed (modifier events are only listened to).
    public mutating func flagsChanged(keyCode: Int64, flagsRaw: UInt64) -> HotkeyTransition? {
        guard let key = ModifierKey(keyCode: keyCode) else { return nil }
        let b = HotkeyBinding.modifier(key: key)
        guard bindings.contains(b) else { return nil }
        let down = (flagsRaw & key.deviceFlagBit) != 0
        guard down != held.contains(b) else { return nil }
        return set(b, down: down)
    }

    public mutating func keyDown(keyCode: Int64, flagsRaw: UInt64, isRepeat: Bool) -> Outcome {
        // Auto-repeat of a key that is already held as a shortcut: swallow quietly.
        if held.contains(where: { if case .key(let c, _) = $0 { return c == keyCode }; return false }) {
            return Outcome(transition: nil, consume: true)
        }
        let b = HotkeyBinding.key(code: keyCode, modifiers: KeyModifiers(flagsRaw: flagsRaw))
        guard bindings.contains(b) else { return .ignored }
        if isRepeat { return Outcome(transition: nil, consume: true) }
        return Outcome(transition: set(b, down: true), consume: true)
    }

    /// A key came up. Ends its shortcut whatever modifiers are still held.
    public mutating func keyUp(keyCode: Int64) -> Outcome {
        guard let b = held.first(where: { if case .key(let c, _) = $0 { return c == keyCode }; return false }) else { return .ignored }
        return Outcome(transition: set(b, down: false), consume: true)
    }

    public mutating func mouseDown(button: Int64) -> Outcome {
        let b = HotkeyBinding.mouse(button: button)
        guard bindings.contains(b) else { return .ignored }
        if held.contains(b) { return Outcome(transition: nil, consume: true) }
        return Outcome(transition: set(b, down: true), consume: true)
    }

    public mutating func mouseUp(button: Int64) -> Outcome {
        let b = HotkeyBinding.mouse(button: button)
        guard bindings.contains(b) else { return .ignored }
        return Outcome(transition: set(b, down: false), consume: true)
    }

    /// Mouse drags with a shortcut button held are swallowed too (otherwise apps see a drag with no press).
    public func consumesMouseDrag(button: Int64) -> Bool { held.contains(.mouse(button: button)) }

    /// After events may have been missed (tap disabled by the system), drop shortcuts that are no longer down.
    public mutating func resync(flagsRaw: UInt64, isKeyDown: (Int64) -> Bool, isButtonDown: (Int64) -> Bool) -> HotkeyTransition? {
        let wasDown = isDown
        held = held.filter { b in
            switch b {
            case .modifier(let key): return (flagsRaw & key.deviceFlagBit) != 0
            case .key(let code, _): return isKeyDown(code)
            case .mouse(let button): return isButtonDown(button)
            }
        }
        return wasDown && !isDown ? .released : nil
    }
}
