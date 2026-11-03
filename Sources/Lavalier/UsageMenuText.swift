import Foundation
import LavalierCore

/// The usage lines shown in the menu, kept in one place so the headless report prints the same text.
enum UsageMenuText {
    static func claudeLine(_ usage: UsageTally) -> String {
        let m = usage.month()
        return String(format: "Claude this month: %d calls, about $%.3f", m.calls, m.estimatedDollars)
    }

    static func lastLine(_ usage: UsageTally) -> String {
        guard let last = usage.last else { return "Last dictation: none yet" }
        let claude = last.claudeMs.map { String(format: ", Claude %.0f ms", $0) } ?? ""
        return String(format: "Last dictation: %.1f s audio, %.0f ms to text (STT %.0f ms%@)", last.audioSeconds, last.totalMs, last.sttMs, claude)
    }

    /// Returns the text and whether it should be shown in the warning colour (under 10% remaining).
    static func creditsLine(_ sub: ElevenLabsSubscription) -> (String, Bool) {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        let reset = sub.nextReset.map { ", resets \(f.string(from: $0))" } ?? ""
        let low = sub.fractionRemaining < 0.10
        return ("ElevenLabs: \(sub.creditsUsed.formatted()) of \(sub.creditLimit.formatted()) credits used\(reset)" + (low ? " · LOW" : ""), low)
    }
}
