import AppKit
import CoreGraphics
import LavalierCore

/// Watches the push-to-talk shortcuts system-wide (several at once, of three kinds).
///
/// - Modifier keys held alone (Right Control, fn, ...): a listen-only CGEventTap on flagsChanged on the main
///   run loop, as before. Falls back to an NSEvent global monitor (needs Accessibility).
/// - Keyboard keys and extra mouse buttons: a second tap on its own thread, created only when such a shortcut
///   exists. It is an active tap where macOS allows it (Accessibility), so the shortcut's presses are kept from
///   the app underneath (a bound F5 does not also reload, mouse button 4 does not also go Back). Seeing
///   keyboard keys system-wide needs Input Monitoring. If only a listen-only tap can be made, the shortcut
///   still works but the key also reaches the app underneath; the menu says so.
///
/// Matching happens in `HotkeyEngine` under a lock, so both threads can use it; transitions are delivered on
/// the main thread in the order they were matched.
@MainActor
final class HotkeyMonitor {
    enum Kind: String { case eventTap = "event tap", globalMonitor = "global monitor" }

    var onTransition: ((HotkeyTransition) -> Void)?
    /// Another of the four listed modifier keys was held alone (the user probably expects it to dictate).
    var onOtherKeyHeld: ((HotkeyChoice) -> Void)?
    /// How modifier keys are watched.
    private(set) var kind: Kind?
    private let engine: HotkeyEngine
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var globalMonitors: [Any] = []
    private var inputTap: InputTapThread?
    private var loggedInputTapFailure = false

    init(bindings: [HotkeyBinding]) {
        engine = HotkeyEngine(bindings: bindings)
        engine.deliver = { [weak self] event in
            guard let self else { return }
            switch event {
            case .transition(let t): self.onTransition?(t)
            case .otherKeyHeld(let k): self.onOtherKeyHeld?(k)
            }
        }
    }

    convenience init(choice: HotkeyChoice) { self.init(bindings: [HotkeyBinding(choice)]) }

    var bindings: [HotkeyBinding] { engine.bindings }
    var isRunning: Bool { kind != nil }

    /// For the menu: how the shortcuts are watched, and whether keyboard/mouse shortcuts are held back.
    var mechanismDescription: String? {
        guard let kind else { return nil }
        guard engine.needsInputTap else { return kind.rawValue }
        switch inputTap?.mode {
        case .active?: return kind.rawValue
        case .listenOnly?: return "\(kind.rawValue); keys also reach other apps"
        case nil: return kind == .globalMonitor ? "\(kind.rawValue); keys also reach other apps" : "\(kind.rawValue); keyboard/mouse shortcuts need Input Monitoring"
        }
    }

    /// While Settings records a new shortcut: no dictation starts and every event passes through untouched.
    var isSuspended: Bool {
        get { engine.isSuspended }
        set { engine.setSuspended(newValue) }
    }

    /// Changes the shortcuts. If one is held, a release is reported first so the caller never waits for a
    /// release that will not come. Installs or removes the keyboard/mouse tap as needed.
    func update(bindings: [HotkeyBinding]) {
        engine.update(bindings: bindings)
        switch kind {
        case nil: return
        case .globalMonitor?: restartGlobalMonitors()
        case .eventTap?:
            // Also retries a keyboard/mouse tap that could not be created earlier (permission granted since).
            if engine.needsInputTap && inputTap == nil { startInputTap() }
            else if !engine.needsInputTap && inputTap != nil { stopInputTap() }
        }
    }

    func update(choice: HotkeyChoice) { update(bindings: [HotkeyBinding(choice)]) }

    /// Installs the monitor if it is not already running. Returns false if no mechanism could be installed.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        if startEventTap() {
            kind = .eventTap
            if engine.needsInputTap { startInputTap() }
            return true
        }
        if startGlobalMonitors() { kind = .globalMonitor; return true }
        kind = nil
        return false
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        stopInputTap()
        for m in globalMonitors { NSEvent.removeMonitor(m) }
        globalMonitors = []
        kind = nil
        engine.releaseAll()
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        engine.resyncFromHardware()
    }

    private func startEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon) else {
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func startInputTap() {
        let thread = InputTapThread(engine: engine)
        thread.start()
        thread.ready.wait()
        if thread.mode == nil {
            if !loggedInputTapFailure {
                Log.app.notice("keyboard/mouse shortcut tap could not be created (Input Monitoring missing?)")
                loggedInputTapFailure = true
            }
            inputTap = nil
        } else {
            loggedInputTapFailure = false
            Log.app.notice("keyboard/mouse shortcut tap: \(thread.mode == .active ? "active (presses held back)" : "listen-only", privacy: .public)")
            inputTap = thread
        }
    }

    private func stopInputTap() {
        inputTap?.stopTap()
        inputTap = nil
    }

    private func startGlobalMonitors() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let engine = self.engine
        var masks: NSEvent.EventTypeMask = [.flagsChanged]
        if engine.needsInputTap { masks.formUnion([.keyDown, .keyUp, .otherMouseDown, .otherMouseUp]) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { event in
            switch event.type {
            case .flagsChanged: engine.flagsChanged(keyCode: Int64(event.keyCode), flagsRaw: UInt64(event.modifierFlags.rawValue))
            case .keyDown: _ = engine.keyDown(keyCode: Int64(event.keyCode), flagsRaw: UInt64(event.modifierFlags.rawValue), isRepeat: event.isARepeat)
            case .keyUp: _ = engine.keyUp(keyCode: Int64(event.keyCode))
            case .otherMouseDown: _ = engine.mouseDown(button: Int64(event.buttonNumber))
            case .otherMouseUp: _ = engine.mouseUp(button: Int64(event.buttonNumber))
            default: break
            }
        }) {
            globalMonitors = [m]
        }
        return !globalMonitors.isEmpty
    }

    private func restartGlobalMonitors() {
        for m in globalMonitors { NSEvent.removeMonitor(m) }
        globalMonitors = []
        if !startGlobalMonitors() { kind = nil }
    }
}

/// Thread-safe matcher shared by the main-thread tap and the keyboard/mouse tap thread.
final class HotkeyEngine: @unchecked Sendable {
    enum Event { case transition(HotkeyTransition), otherKeyHeld(HotkeyChoice) }

    private let lock = NSLock()
    private var matcher: HotkeyMatcher
    private var wrongKey: WrongKeyDetector
    private var suspended = false
    /// Called on the main thread.
    @MainActor var deliver: ((Event) -> Void)?

    init(bindings: [HotkeyBinding]) {
        matcher = HotkeyMatcher(bindings: bindings)
        wrongKey = WrongKeyDetector(bindings: bindings)
    }

    var bindings: [HotkeyBinding] { lock.withLock { matcher.bindings } }
    var needsInputTap: Bool { lock.withLock { matcher.needsKeyEvents || matcher.needsMouseEvents } }
    var isSuspended: Bool { lock.withLock { suspended } }

    /// Must be called with the lock held, so events reach the main queue in the order they were matched.
    private func post(_ event: Event?) {
        guard let event else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver?(event) } }
    }

    private func post(_ t: HotkeyTransition?) { post(t.map(Event.transition)) }

    func update(bindings: [HotkeyBinding]) {
        lock.withLock {
            post(matcher.update(bindings: bindings))
            wrongKey.update(bindings: bindings)
        }
    }

    func setSuspended(_ value: Bool) {
        lock.withLock {
            suspended = value
            if value { post(matcher.releaseAll()) }
        }
    }

    func releaseAll() { lock.withLock { post(matcher.releaseAll()) } }

    func flagsChanged(keyCode: Int64, flagsRaw: UInt64) {
        lock.withLock {
            guard !suspended else { return }
            post(matcher.flagsChanged(keyCode: keyCode, flagsRaw: flagsRaw))
            if let other = wrongKey.handle(keyCode: keyCode, flagsRaw: flagsRaw, at: ProcessInfo.processInfo.systemUptime) {
                post(.otherKeyHeld(other))
            }
        }
    }

    /// Each returns true when the event belongs to a shortcut and should not reach other apps.
    func keyDown(keyCode: Int64, flagsRaw: UInt64, isRepeat: Bool) -> Bool {
        handle { $0.keyDown(keyCode: keyCode, flagsRaw: flagsRaw, isRepeat: isRepeat) }
    }
    func keyUp(keyCode: Int64) -> Bool { handle { $0.keyUp(keyCode: keyCode) } }
    func mouseDown(button: Int64) -> Bool { handle { $0.mouseDown(button: button) } }
    func mouseUp(button: Int64) -> Bool { handle { $0.mouseUp(button: button) } }
    func mouseDragged(button: Int64) -> Bool {
        lock.withLock { !suspended && matcher.consumesMouseDrag(button: button) }
    }

    private func handle(_ body: (inout HotkeyMatcher) -> HotkeyMatcher.Outcome) -> Bool {
        lock.withLock {
            guard !suspended else { return false }
            let outcome = body(&matcher)
            post(outcome.transition)
            return outcome.consume
        }
    }

    /// After a tap was disabled and re-enabled, a release may have been missed; drop anything no longer down.
    func resyncFromHardware() {
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let buttons = NSEvent.pressedMouseButtons
        lock.withLock {
            post(matcher.resync(flagsRaw: flags,
                                isKeyDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) },
                                isButtonDown: { $0 < 64 && (buttons & (1 << Int($0))) != 0 }))
        }
    }
}

/// Runs the keyboard/mouse tap on its own run loop, so a busy main thread never delays typing or clicking.
private final class InputTapThread: Thread, @unchecked Sendable {
    enum Mode { case active, listenOnly }

    let engine: HotkeyEngine
    let ready = DispatchSemaphore(value: 0)
    private(set) var mode: Mode?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    init(engine: HotkeyEngine) {
        self.engine = engine
        super.init()
        name = "Lavalier shortcut tap"
        qualityOfService = .userInteractive
    }

    static let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

    override func main() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: Self.mask, callback: inputTapCallback, userInfo: refcon) {
            port = p
            mode = .active
        } else if let p = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                            eventsOfInterest: Self.mask, callback: inputTapCallback, userInfo: refcon) {
            port = p
            mode = .listenOnly
        }
        guard let port else { ready.signal(); return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        ready.signal()
        CFRunLoopRun()
    }

    func stopTap() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
        engine.resyncFromHardware()
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    guard let refcon else { return pass }
    let thread = Unmanaged<InputTapThread>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        thread.reenable()
        return pass
    }
    // Lavalier's own synthetic events (the paste after a dictation) are never shortcuts.
    if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return pass }
    let engine = thread.engine
    let consume: Bool
    switch type {
    case .keyDown:
        consume = engine.keyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flagsRaw: event.flags.rawValue,
                                 isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    case .keyUp:
        consume = engine.keyUp(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
    case .otherMouseDown:
        consume = engine.mouseDown(button: event.getIntegerValueField(.mouseEventButtonNumber))
    case .otherMouseUp:
        consume = engine.mouseUp(button: event.getIntegerValueField(.mouseEventButtonNumber))
    case .otherMouseDragged:
        consume = engine.mouseDragged(button: event.getIntegerValueField(.mouseEventButtonNumber))
    default:
        consume = false
    }
    return consume && thread.mode == .active ? nil : pass
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Task { @MainActor in monitor.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
        monitor.engineForTap.flagsChanged(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flagsRaw: event.flags.rawValue)
    }
    return Unmanaged.passUnretained(event)
}

extension HotkeyMonitor {
    /// The flags tap runs on the main run loop; the engine itself is thread-safe.
    nonisolated var engineForTap: HotkeyEngine { engine }
}
