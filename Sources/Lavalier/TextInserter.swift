import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LavalierCore

enum InsertPath: String { case accessibility, paste }

struct InsertResult {
    let path: InsertPath
    let milliseconds: Double
    let note: String?
    /// Bundle identifier of the app that received the text, for the timing log.
    let app: String?
}

/// Puts text at the cursor of the frontmost app. Accessibility first (no clipboard involved) for native
/// text fields whose value can be read back, then paste with the clipboard saved and restored. Web content
/// (browsers, Electron apps) is paste-only: see `InsertionPolicy`.
@MainActor
final class TextInserter {
    /// How long the target app gets to read the pasteboard before it is restored.
    static let pasteSettleSeconds = 0.30
    /// Native roles where setting the selected text is known to insert at the caret.
    private static let accessibilityRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
    /// How far up the element tree to look for a web content root.
    static let ancestorWalkLimit = 12

    enum AccessibilityAttempt {
        case inserted(note: String)
        case skipped(reason: String)
    }

    func insert(_ text: String) async throws -> InsertResult {
        guard !text.isEmpty else { throw DictationError.insertionFailed("nothing to insert") }
        guard AXIsProcessTrusted() else { throw DictationError.permissionMissing("Accessibility") }
        let started = nowMs()
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var notes: [String] = []
        switch tryAccessibility(text, bundleID: app) {
        case .inserted(let note):
            return InsertResult(path: .accessibility, milliseconds: nowMs() - started, note: note, app: app)
        case .skipped(let reason):
            notes.append(reason)
        }
        if let pasteNote = try await paste(text) { notes.append(pasteNote) }
        return InsertResult(path: .paste, milliseconds: nowMs() - started, note: notes.joined(separator: "; "), app: app)
    }

    /// The set call is only attempted when the element's value can be read before and after, so a silent
    /// no-op is caught and an unverifiable element never risks a double insert. Every skip says why, so a
    /// logged dictation shows which route was taken and for what reason.
    private func tryAccessibility(_ text: String, bundleID: String?) -> AccessibilityAttempt {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return .skipped(reason: "no focused element") }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 1.0)
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "unknown role"
        guard TextInserter.accessibilityRoles.contains(role) else { return .skipped(reason: "focused \(role)") }
        if let reason = InsertionPolicy.pasteOnlyReason(bundleID: bundleID, ancestorRoles: ancestorRoles(of: element)) {
            return .skipped(reason: "paste only: \(reason)")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return .skipped(reason: "\(role) selected text not settable") }
        var beforeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &beforeRef) == .success,
              let before = beforeRef as? String, before.utf16.count < 200_000 else { return .skipped(reason: "\(role) value unreadable") }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return .skipped(reason: "\(role) refused the write")
        }
        var afterRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &afterRef) == .success,
              let after = afterRef as? String else {
            // Could not read back; the set may have landed. Report it rather than paste a second copy.
            return .inserted(note: "AX \(role), unverified")
        }
        if after == before { return .skipped(reason: "AX \(role) accepted the write but its value did not change") }
        return .inserted(note: "AX \(role)")
    }

    /// Roles of the element's ancestors, nearest first, stopping at a web content root.
    private func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current = element
        for _ in 0..<TextInserter.ancestorWalkLimit {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else { break }
            let parent = parentRef as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String {
                roles.append(role)
                if role == InsertionPolicy.webContentRole { break }
            }
            current = parent
        }
        return roles
    }

    private func paste(_ text: String) async throws -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        guard let ourChange = PasteboardSnapshot.writeTransient(text: text, to: pasteboard) else {
            throw DictationError.insertionFailed("could not write to the clipboard")
        }
        guard postCommandV() else {
            snapshot.restore(to: pasteboard)
            throw DictationError.insertionFailed("Cmd-V could not be posted")
        }
        try? await Task.sleep(nanoseconds: UInt64(TextInserter.pasteSettleSeconds * 1_000_000_000))
        var notes: [String] = []
        if pasteboard.changeCount != ourChange {
            notes.append("clipboard changed during paste; left as is")
        } else if snapshot.isUnrestorable {
            notes.append("previous clipboard held only unreadable types (\(snapshot.unreadableTypes.joined(separator: ", "))); dictated text left on the clipboard")
        } else {
            if !snapshot.restore(to: pasteboard) { notes.append("clipboard restore reported failure") }
            if !snapshot.unreadableTypes.isEmpty { notes.append("clipboard types not restorable: \(snapshot.unreadableTypes.joined(separator: ", "))") }
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    private func postCommandV() -> Bool {
        let keyCode = TextInserter.keyCode(for: "v") ?? 9
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Finds the virtual key that produces `character` on the current keyboard layout (Dvorak, Colemak…).
    static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = unsafeBitCast(layoutPtr, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]),
                   Character(scalar) == character {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
