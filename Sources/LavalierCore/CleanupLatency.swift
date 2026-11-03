import Foundation

/// Latency measures for the Claude cleanup step (measured 3 November 2026):
///
/// Speculative start. At key release the live transcript (the last partial) often already holds the whole
/// dictation, when the speaker paused briefly before releasing. The cleanup then starts on it straight away
/// instead of waiting 0.2 to 0.4 s for ElevenLabs' committed transcript. The speculative result is used only
/// when the committed transcript has exactly the same words (`CleanupSpeculation.sameWords`); otherwise it
/// is discarded and the cleanup runs on the committed text as before (one extra Haiku call, about $0.00005).
///
/// Parallel requests (`firstSuccess`, `PipelineConfig.parallelCleanupRequests`) are off by default: two
/// identical requests were no faster than one over 12 runs.
public enum CleanupSpeculation {
    /// Words only: lower case, letters and digits, apostrophes kept inside words. Punctuation and
    /// capitalisation are what the cleanup step adds anyway, so they do not count as a difference.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// True when the speculative input and the committed transcript say the same words in the same order.
    public static func sameWords(_ speculative: String, _ committed: String) -> Bool {
        let a = words(speculative)
        return !a.isEmpty && a == words(committed)
    }
}

/// Runs `count` copies of `operation` at once (each given its index) and returns the first success; the others are cancelled.
/// Throws the first error only when every copy failed.
public func firstSuccess<T: Sendable>(count: Int, _ operation: @escaping @Sendable (Int) async throws -> T) async throws -> T {
    let n = max(1, count)
    return try await withThrowingTaskGroup(of: T.self) { group in
        for i in 0..<n { group.addTask { try await operation(i) } }
        var firstError: Error?
        while true {
            do {
                guard let value = try await group.next() else { break }
                group.cancelAll()
                return value
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? CancellationError()
    }
}

/// Holds the latest value written from another task (the live transcript).
final class LatestBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T?
    var value: T? { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
}
