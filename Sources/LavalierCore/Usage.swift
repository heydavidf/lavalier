import Foundation

/// Local tally of Claude calls this month, persisted as JSON. The Anthropic usage report needs an
/// Admin API key, so the app counts what it sent and received itself.
public struct UsageTally: Codable, Equatable, Sendable {
    public struct Month: Codable, Equatable, Sendable {
        public var key: String
        public var calls: Int = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        public var cacheReadTokens: Int = 0
        public var dictations: Int = 0
        public var audioSeconds: Double = 0

        public var estimatedDollars: Double {
            ClaudeUsage(inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens).estimatedDollars
        }
    }

    public struct LastDictation: Codable, Equatable, Sendable {
        public var at: Date
        public var audioSeconds: Double
        public var sttMs: Double
        public var claudeMs: Double?
        public var totalMs: Double
    }

    public var months: [Month] = []
    public var last: LastDictation?

    public init() {}

    public static func monthKey(for date: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    public func month(_ key: String = UsageTally.monthKey()) -> Month {
        months.first(where: { $0.key == key }) ?? Month(key: key)
    }

    public mutating func record(usage: ClaudeUsage?, audioSeconds: Double, sttMs: Double, claudeMs: Double?, totalMs: Double, at: Date = Date()) {
        let key = UsageTally.monthKey(for: at)
        var m = month(key)
        if let u = usage {
            m.calls += 1
            m.inputTokens += u.inputTokens
            m.outputTokens += u.outputTokens
            m.cacheReadTokens += u.cacheReadTokens
        }
        m.dictations += 1
        m.audioSeconds += audioSeconds
        months.removeAll { $0.key == key }
        months.append(m)
        months.sort { $0.key < $1.key }
        if months.count > 24 { months.removeFirst(months.count - 24) }
        last = LastDictation(at: at, audioSeconds: audioSeconds, sttMs: sttMs, claudeMs: claudeMs, totalMs: totalMs)
    }

    // Persistence
    public static func fileURL(in directory: URL = AppPaths.supportDirectory) -> URL {
        directory.appendingPathComponent("usage.json")
    }

    public static func load(from url: URL = fileURL()) -> UsageTally {
        guard let data = try? Data(contentsOf: url),
              let t = try? JSONDecoder.iso.decode(UsageTally.self, from: data) else { return UsageTally() }
        return t
    }

    public func save(to url: URL = fileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}

/// Opt-in text log of each dictation's timings. Never audio, never keys.
public struct TimingLog {
    public static func fileURL(in directory: URL = AppPaths.supportDirectory) -> URL {
        directory.appendingPathComponent("timings.jsonl")
    }

    public static func append(_ outcome: DictationOutcome, insertMs: Double?, insertPath: String?, app: String? = nil, to url: URL = fileURL()) {
        var record: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "audio_s": outcome.audioSeconds,
            "connect_ms": outcome.connectMs.rounded(),
            "stt_ms": outcome.sttMs.rounded(),
            "total_ms": outcome.totalMs.rounded(),
            "raw": outcome.raw,
            "final": outcome.finalText,
            "partials": outcome.partialCount,
        ]
        if let c = outcome.claudeMs { record["claude_ms"] = c.rounded() }
        if let r = outcome.cleanupSkippedReason { record["cleanup_skipped"] = r }
        if let e = outcome.cleanupError { record["cleanup_error"] = e.userMessage }
        if let u = outcome.claudeUsage { record["tokens_in"] = u.inputTokens; record["tokens_out"] = u.outputTokens }
        if outcome.claudeRequests > 0 { record["claude_requests"] = outcome.claudeRequests }
        if let s = outcome.speculation { record["speculation"] = s }
        if let i = insertMs { record["insert_ms"] = i.rounded() }
        if let p = insertPath { record["insert_path"] = p }
        if let a = app { record["insert_app"] = a }
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
}
