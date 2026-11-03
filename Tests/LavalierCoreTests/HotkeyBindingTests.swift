import XCTest
import CoreGraphics
@testable import LavalierCore

/// Several push-to-talk shortcuts at once (modifier keys, keyboard keys, mouse buttons).
final class HotkeyBindingTests: XCTestCase {
    private let rightCtrlDown: UInt64 = CGEventFlags.maskControl.rawValue | 0x2000
    private let none: UInt64 = 0

    func testAnyOfSeveralShortcutsStartsAndTheLastReleaseEnds() {
        var m = HotkeyMatcher(bindings: [.modifier(key: .rightControl), .mouse(button: 3), .key(code: 105, modifiers: [])])
        // Mouse button 4 alone.
        XCTAssertEqual(m.mouseDown(button: 3), .init(transition: .pressed, consume: true))
        XCTAssertEqual(m.mouseUp(button: 3), .init(transition: .released, consume: true))
        // F13 alone, with auto-repeat swallowed.
        XCTAssertEqual(m.keyDown(keyCode: 105, flagsRaw: none, isRepeat: false), .init(transition: .pressed, consume: true))
        XCTAssertEqual(m.keyDown(keyCode: 105, flagsRaw: none, isRepeat: true), .init(transition: nil, consume: true))
        XCTAssertEqual(m.keyUp(keyCode: 105), .init(transition: .released, consume: true))
        // Right Control alone.
        XCTAssertEqual(m.flagsChanged(keyCode: 62, flagsRaw: rightCtrlDown), .pressed)
        XCTAssertEqual(m.flagsChanged(keyCode: 62, flagsRaw: none), .released)
        // Overlap: Right Control, then the mouse button, release Control: still dictating until the button comes up.
        XCTAssertEqual(m.flagsChanged(keyCode: 62, flagsRaw: rightCtrlDown), .pressed)
        XCTAssertNil(m.mouseDown(button: 3).transition)
        XCTAssertNil(m.flagsChanged(keyCode: 62, flagsRaw: none))
        XCTAssertEqual(m.mouseUp(button: 3).transition, .released)
    }

    func testUnboundEventsPassThroughUntouched() {
        var m = HotkeyMatcher(bindings: [.mouse(button: 3), .key(code: 105, modifiers: [])])
        XCTAssertEqual(m.mouseDown(button: 2), .ignored, "middle button is not a shortcut here")
        XCTAssertEqual(m.keyDown(keyCode: 0, flagsRaw: none, isRepeat: false), .ignored, "typing A is untouched")
        XCTAssertEqual(m.keyUp(keyCode: 0), .ignored)
        XCTAssertNil(m.flagsChanged(keyCode: 62, flagsRaw: rightCtrlDown), "Right Control is not a shortcut here")
        XCTAssertFalse(m.isDown)
    }

    func testKeyCombinationNeedsExactlyItsModifiers() {
        let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        var m = HotkeyMatcher(bindings: [.key(code: 49, modifiers: [.control, .option])])
        XCTAssertEqual(m.keyDown(keyCode: 49, flagsRaw: none, isRepeat: false), .ignored, "plain Space still types")
        XCTAssertEqual(m.keyDown(keyCode: 49, flagsRaw: ctrlOpt | CGEventFlags.maskCommand.rawValue, isRepeat: false), .ignored)
        XCTAssertEqual(m.keyDown(keyCode: 49, flagsRaw: ctrlOpt, isRepeat: false).transition, .pressed)
        // Letting go of the modifiers first does not end it; the key itself does.
        XCTAssertEqual(m.keyUp(keyCode: 49).transition, .released)
    }

    func testLeftAndRightModifiersAreToldApart() {
        var m = HotkeyMatcher(bindings: [.modifier(key: .leftOption)])
        let rightOpt = CGEventFlags.maskAlternate.rawValue | 0x40
        let leftOpt = CGEventFlags.maskAlternate.rawValue | 0x20
        XCTAssertNil(m.flagsChanged(keyCode: 61, flagsRaw: rightOpt), "Right Option is not Left Option")
        XCTAssertEqual(m.flagsChanged(keyCode: 58, flagsRaw: leftOpt), .pressed)
        XCTAssertEqual(m.flagsChanged(keyCode: 58, flagsRaw: none), .released)
        var fn = HotkeyMatcher(bindings: [.modifier(key: .fn)])
        XCTAssertEqual(fn.flagsChanged(keyCode: 63, flagsRaw: CGEventFlags.maskSecondaryFn.rawValue), .pressed)
        XCTAssertEqual(fn.flagsChanged(keyCode: 63, flagsRaw: none), .released)
    }

    func testChangingShortcutsWhileHeldReportsARelease() {
        var m = HotkeyMatcher(bindings: [.mouse(button: 4)])
        XCTAssertEqual(m.mouseDown(button: 4).transition, .pressed)
        XCTAssertEqual(m.update(bindings: [.mouse(button: 3)]), .released)
        XCTAssertFalse(m.isDown)
        XCTAssertNil(m.update(bindings: [.mouse(button: 3)]), "same list: nothing to report")
    }

    func testResyncDropsShortcutsNoLongerHeld() {
        var m = HotkeyMatcher(bindings: [.mouse(button: 3), .key(code: 105, modifiers: [])])
        _ = m.mouseDown(button: 3)
        _ = m.keyDown(keyCode: 105, flagsRaw: 0, isRepeat: false)
        XCTAssertNil(m.resync(flagsRaw: 0, isKeyDown: { _ in true }, isButtonDown: { _ in false }), "F13 still held")
        XCTAssertEqual(m.resync(flagsRaw: 0, isKeyDown: { _ in false }, isButtonDown: { _ in false }), .released)
    }

    func testMouseDragWithAShortcutButtonHeldIsSwallowed() {
        var m = HotkeyMatcher(bindings: [.mouse(button: 2)])
        XCTAssertFalse(m.consumesMouseDrag(button: 2))
        _ = m.mouseDown(button: 2)
        XCTAssertTrue(m.consumesMouseDrag(button: 2))
    }

    func testLeftAndRightClickCanNeverBeShortcuts() {
        XCTAssertFalse(HotkeyBinding.acceptsMouseButton(0))
        XCTAssertFalse(HotkeyBinding.acceptsMouseButton(1))
        XCTAssertTrue(HotkeyBinding.acceptsMouseButton(2))
        XCTAssertTrue(HotkeyBinding.acceptsMouseButton(4))
    }

    func testLabelsAndNotes() {
        XCTAssertEqual(HotkeyBinding.key(code: 49, modifiers: [.control, .option]).label, "⌃⌥Space")
        XCTAssertEqual(HotkeyBinding.key(code: 105, modifiers: []).label, "F13")
        XCTAssertEqual(HotkeyBinding.mouse(button: 3).label, "Mouse button 4 (side, often Back)")
        XCTAssertEqual(HotkeyBinding.modifier(key: .rightControl).label, HotkeyChoice.rightControl.label)
        XCTAssertNotNil(HotkeyBinding.key(code: 0, modifiers: []).note, "a letter would stop typing")
        XCTAssertNil(HotkeyBinding.key(code: 105, modifiers: []).note, "F13 needs no warning")
        XCTAssertNotNil(HotkeyBinding.mouse(button: 3).note)
        XCTAssertEqual(HotkeyBinding.modifier(key: .rightCommand).note, HotkeyChoice.rightCommand.note, "existing warnings kept")
        XCTAssertEqual([HotkeyBinding.modifier(key: .fn), .mouse(button: 2), .key(code: 105, modifiers: [])].spokenList,
                       "fn / Globe, Middle mouse button or F13")
    }
}

/// Several shortcuts must not change the default: without a saved list, the single saved
/// key is used, and without that, `HotkeyChoice.default`.
final class HotkeyListSettingsTests: XCTestCase {
    private func freshSettings() -> AppSettings {
        // One fixed name, emptied before and after each test, so runs do not leave a new preferences file each time.
        let name = "lavalier.tests.hotkeys"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return AppSettings(defaults: d)
    }

    func testNoSavedListFallsBackToTheSingleKeyAndTheUnchangedDefault() {
        let s = freshSettings()
        XCTAssertEqual(s.hotkeys, [HotkeyBinding(HotkeyChoice.default)])
        s.hotkey = .fn
        XCTAssertEqual(s.hotkeys, [.modifier(key: .fn)], "an existing single-key choice carries over")
    }

    func testSavedListRoundTripsWithoutDuplicates() {
        let s = freshSettings()
        let list: [HotkeyBinding] = [.modifier(key: .rightControl), .mouse(button: 3), .key(code: 49, modifiers: [.control, .option]), .mouse(button: 3)]
        s.hotkeys = list
        XCTAssertEqual(s.hotkeys, [.modifier(key: .rightControl), .mouse(button: 3), .key(code: 49, modifiers: [.control, .option])])
        XCTAssertEqual(s.hotkey, .default, "the single-key setting is left as it was")
        s.hotkeys = []
        XCTAssertEqual(s.hotkeys, [HotkeyBinding(HotkeyChoice.default)], "never empty")
    }

    func testWrongKeyHintIgnoresEveryBoundKey() {
        var d = WrongKeyDetector(bindings: [.modifier(key: .rightControl), .modifier(key: .fn), .mouse(button: 3)])
        let fnFlags = CGEventFlags.maskSecondaryFn.rawValue
        XCTAssertNil(d.handle(keyCode: 63, flagsRaw: fnFlags, at: 0))
        XCTAssertNil(d.handle(keyCode: 63, flagsRaw: 0, at: 2), "fn is a shortcut, so no hint")
        let rightCmd = CGEventFlags.maskCommand.rawValue | 0x10
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: rightCmd, at: 10))
        XCTAssertEqual(d.handle(keyCode: 54, flagsRaw: 0, at: 11), .rightCommand, "an unbound listed key still gets the hint")
    }
}
