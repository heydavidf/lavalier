import AppKit

/// Menu-bar icon options, chosen in Settings > General. The default is a lavalier microphone: a capsule on
/// a cable ending in a clip, which nothing in macOS uses, so it cannot be mistaken for the system microphone
/// indicator. All glyphs are template images, 18 by 18 points, drawn with paths so they stay crisp.
public enum MenuBarGlyphStyle: String, CaseIterable, Codable, Sendable {
    case lavalier
    case cableLoop
    case pillWave
    case monogram
    case systemMic

    public static let `default`: MenuBarGlyphStyle = .lavalier

    public var label: String {
        switch self {
        case .lavalier: return "Lavalier mic (capsule, cable, clip)"
        case .cableLoop: return "Capsule with cable loop"
        case .pillWave: return "Waveform in a pill"
        case .monogram: return "L monogram with capsule"
        case .systemMic: return "System microphone symbol"
        }
    }

    public var blurb: String {
        switch self {
        case .lavalier: return "Reads as a clip-on lapel mic. Distinct from every macOS microphone glyph."
        case .cableLoop: return "Same capsule, cable coiled below. Rounder, a little more abstract."
        case .pillWave: return "No microphone at all: three bars in a pill. Quiet, could be read as audio levels."
        case .monogram: return "The letter L with the capsule as its dot. Brand-like; least like a tool icon."
        case .systemMic: return "Looks like the macOS dictation and privacy indicators."
        }
    }
}

public enum MenuBarGlyphState: String, CaseIterable, Sendable {
    case idle, listening, processing, disabled, attention

    /// The SF Symbol used by the `systemMic` style.
    var systemSymbolName: String {
        switch self {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .processing: return "ellipsis.circle"
        case .disabled: return "mic.slash"
        case .attention: return "exclamationmark.triangle"
        }
    }
}

public enum MenuBarGlyph {
    public static let size = NSSize(width: 18, height: 18)

    /// Template image for the status item button.
    public static func image(style: MenuBarGlyphStyle, state: MenuBarGlyphState) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(style: style, state: state, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// PNG for previews (black glyph on transparent), `scale` pixels per point.
    public static func png(style: MenuBarGlyphStyle, state: MenuBarGlyphState, scale: CGFloat = 4) -> Data? {
        let px = Int(size.width * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(style: style, state: state, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Drawing

    static func draw(style: MenuBarGlyphStyle, state: MenuBarGlyphState, in rect: NSRect) {
        if style == .systemMic {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let symbol = NSImage(systemSymbolName: state.systemSymbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return
        }
        let dimmed = state == .processing
        let color = NSColor.black.withAlphaComponent(dimmed ? 0.4 : 1.0)
        let filled = state == .listening
        switch style {
        case .lavalier: drawLavalier(filled: filled, color: color)
        case .cableLoop: drawCableLoop(filled: filled, color: color)
        case .pillWave: drawPillWave(active: filled, color: color)
        case .monogram: drawMonogram(filled: filled, color: color)
        case .systemMic: break
        }
        NSColor.black.set()
        switch state {
        case .processing:
            for x in [5.0, 9.0, 13.0] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.2, y: 7.8, width: 2.4, height: 2.4)).fill()
            }
        case .disabled:
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3, y: 2.5))
            slash.line(to: NSPoint(x: 15, y: 15.5))
            slash.lineWidth = 1.6
            slash.lineCapStyle = .round
            slash.stroke()
        case .attention:
            NSBezierPath(ovalIn: NSRect(x: 11.5, y: 11.5, width: 6, height: 6)).fill()
        case .idle, .listening:
            break
        }
    }

    /// Capsule 4.5 by 7 at the top centre. Outline when idle, solid when listening.
    private static func capsule(filled: Bool, color: NSColor) {
        color.set()
        let frame = NSRect(x: 6.75, y: 10, width: 4.5, height: 7)
        if filled {
            NSBezierPath(roundedRect: frame, xRadius: 2.25, yRadius: 2.25).fill()
        } else {
            let inset = frame.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: inset, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private static func drawLavalier(filled: Bool, color: NSColor) {
        capsule(filled: filled, color: color)
        color.set()
        let cable = NSBezierPath()
        cable.move(to: NSPoint(x: 9, y: 10))
        cable.curve(to: NSPoint(x: 5.5, y: 3.6), controlPoint1: NSPoint(x: 9, y: 7), controlPoint2: NSPoint(x: 5.5, y: 6.8))
        cable.lineWidth = 1.5
        cable.lineCapStyle = .round
        cable.stroke()
        NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.5, width: 6, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
    }

    private static func drawCableLoop(filled: Bool, color: NSColor) {
        capsule(filled: filled, color: color)
        color.set()
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 10))
        stem.line(to: NSPoint(x: 9, y: 7.2))
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.stroke()
        let loop = NSBezierPath(ovalIn: NSRect(x: 5.75, y: 1.75, width: 6.5, height: 5.6))
        loop.lineWidth = 1.5
        loop.stroke()
    }

    private static func drawPillWave(active: Bool, color: NSColor) {
        color.set()
        let pill = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 4.75, width: 14.5, height: 8.5), xRadius: 4.25, yRadius: 4.25)
        pill.lineWidth = 1.5
        pill.stroke()
        let heights: [CGFloat] = active ? [4.5, 7, 4.5] : [2.5, 5, 2.5]
        for (i, x) in [6.0, 9.0, 12.0].enumerated() {
            let h = heights[i]
            NSBezierPath(roundedRect: NSRect(x: x - 0.8, y: 9 - h / 2, width: 1.6, height: h), xRadius: 0.8, yRadius: 0.8).fill()
        }
    }

    private static func drawMonogram(filled: Bool, color: NSColor) {
        color.set()
        let l = NSBezierPath()
        l.move(to: NSPoint(x: 4.75, y: 15.5))
        l.line(to: NSPoint(x: 4.75, y: 3.5))
        l.line(to: NSPoint(x: 12, y: 3.5))
        l.lineWidth = 2.5
        l.lineCapStyle = .round
        l.lineJoinStyle = .round
        l.stroke()
        let dot = NSRect(x: 12.25, y: 10.5, width: 3.5, height: 5.5)
        if filled {
            NSBezierPath(roundedRect: dot, xRadius: 1.75, yRadius: 1.75).fill()
        } else {
            let p = NSBezierPath(roundedRect: dot.insetBy(dx: 0.6, dy: 0.6), xRadius: 1.15, yRadius: 1.15)
            p.lineWidth = 1.2
            p.stroke()
        }
    }
}
