import AppKit

/// Floating, click-through panel near the bottom of the screen the mouse is on. While the key is held it shows
/// a pulsing red dot, "Listening…" and the live transcript; after release "Transcribing…"; then a result or
/// error line for a moment. Also carries the launch cue. Never takes focus.
@MainActor
final class DictationHUD {
    enum Content {
        case listening(partial: String?)
        case processing
        case message(String, isError: Bool)
    }

    private let panel: NSPanel
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var pulse: Timer?
    private var hideTimer: Timer?
    private var pulseOn = true

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 66),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 66))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        panel.contentView = effect

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingHead
        detail.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(dot)
        effect.addSubview(title)
        effect.addSubview(detail)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            dot.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows `content`; with `seconds` it hides itself afterwards.
    func show(_ content: Content, for seconds: Double? = nil) {
        hideTimer?.invalidate()
        hideTimer = nil
        switch content {
        case .listening(let partial):
            title.stringValue = "Listening…"
            detail.stringValue = partial ?? "Speak, then release the key."
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            startPulse()
        case .processing:
            title.stringValue = "Transcribing…"
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopPulse()
        case .message(let text, let isError):
            title.stringValue = text
            detail.stringValue = ""
            dot.isHidden = false
            dot.layer?.backgroundColor = (isError ? NSColor.systemRed : NSColor.systemGreen).cgColor
            stopPulse()
        }
        position()
        panel.orderFrontRegardless()
        if let seconds {
            hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }
        }
    }

    /// Live transcript while listening; the tail stays visible.
    func update(partial: String) {
        guard panel.isVisible, title.stringValue == "Listening…" else { return }
        detail.stringValue = partial
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopPulse()
        panel.orderOut(nil)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 72)
        panel.setFrameOrigin(origin)
    }

    private func startPulse() {
        stopPulse()
        pulseOn = true
        dot.alphaValue = 1
        pulse = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pulseOn.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    self.dot.animator().alphaValue = self.pulseOn ? 1 : 0.3
                }
            }
        }
    }

    private func stopPulse() {
        pulse?.invalidate()
        pulse = nil
        dot.alphaValue = 1
    }
}
