import Foundation

/// The cleanup prompt, with the personal dictionary spliced in.
public enum Cleanup {
    public static let model = "claude-haiku-5-5"
    public static let minimumWords = 4

    /// Output allowance for one cleanup. A fixed 1,024 tokens cut long dictations short (five
    /// minutes of speech is about 900 words, about 1,200 tokens). About 3 tokens per input word, never
    /// below the old 1,024, capped at 8,192.
    public static func maxTokens(for raw: String) -> Int {
        min(8192, max(1024, wordCount(raw) * 3))
    }

    /// Extra seconds allowed for cleanup per input word, on top of the configured timeout.
    public static let timeoutSecondsPerWord = 0.01

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Short dictations are inserted raw: cleanup adds latency and the gain is nil.
    public static func shouldClean(_ raw: String, minimumWords: Int = Cleanup.minimumWords) -> Bool {
        wordCount(raw) >= minimumWords
    }

    public static func systemPrompt(dictionary: [String]) -> String {
        var lines = [
            "You clean up dictated speech into written text. Return only the cleaned text, nothing else.",
            "Rules:",
            "- Remove filler words (um, uh, you know, like, so at sentence starts, okay so).",
            "- Add punctuation, capitalisation and paragraph breaks where natural.",
            "- Honour spoken self-corrections: when the speaker says 'no wait', 'I mean', 'scratch that', 'actually', keep only the corrected version and drop the retracted words.",
            "- Keep the speaker's wording, tone and meaning otherwise. Do not summarise, expand or answer.",
            "- Use British spelling.",
        ]
        if !dictionary.isEmpty {
            lines.append("- Use these spellings for names and products: " + dictionary.joined(separator: ", ") + ".")
        }
        lines.append("- If the input is a list of items, format it as a list.")
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct ClaudeUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    /// Published Haiku 5.5 prices: $0.10 per million input, $0.50 per million output, $0.01 cache read.
    public var estimatedDollars: Double {
        Double(inputTokens) * 0.10 / 1_000_000
            + Double(outputTokens) * 0.50 / 1_000_000
            + Double(cacheReadTokens) * 0.01 / 1_000_000
    }
}

public struct CleanupResponse: Sendable {
    public let text: String
    public let usage: ClaudeUsage
    public let milliseconds: Double
    public let model: String
}

/// Calls the Claude Messages API over plain HTTPS. There is no official Swift SDK.
public final class ClaudeClient: Sendable {
    public static var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static var modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!

    private let apiKey: String
    private let session: URLSession
    private let model: String

    public init(apiKey: String, session: URLSession = ClaudeClient.makeSession(), model: String = Cleanup.model) {
        self.apiKey = apiKey
        self.session = session
        self.model = model
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }

    public func cleanup(raw: String, systemPrompt: String, timeout: TimeInterval = 6) async throws -> CleanupResponse {
        var request = URLRequest(url: ClaudeClient.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Cleanup.maxTokens(for: raw),
            "system": [["type": "text", "text": systemPrompt]],
            "messages": [["role": "user", "content": raw]],
            "output_config": ["effort": "low"],
        ]
        // Haiku 5.5 accepts thinking disabled at effort low (measured fastest in early tests). Sonnet 5.5 and
        // Opus 5.5 reject it with a 400, so they run with their default adaptive thinking at low effort.
        if model.hasPrefix("claude-haiku") { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = nowMs()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw DictationError.cleanupTimeout
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw DictationError.offline
        } catch {
            throw DictationError.network(error.localizedDescription)
        }
        let elapsed = nowMs() - started
        guard let http = response as? HTTPURLResponse else { throw DictationError.badResponse(.anthropic, "no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw DictationError.http(service: .anthropic, status: http.statusCode, message: message)
        }
        guard let content = json?["content"] as? [[String: Any]] else {
            throw DictationError.badResponse(.anthropic, "no content array")
        }
        if let stop = json?["stop_reason"] as? String, stop == "refusal" {
            throw DictationError.badResponse(.anthropic, "refusal")
        }
        // A cleanup that ran out of tokens is missing its end: insert the raw transcript instead.
        if let stop = json?["stop_reason"] as? String, stop == "max_tokens" {
            throw DictationError.badResponse(.anthropic, "cleanup cut short (max_tokens)")
        }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let u = json?["usage"] as? [String: Any] ?? [:]
        let usage = ClaudeUsage(inputTokens: u["input_tokens"] as? Int ?? 0,
                                outputTokens: u["output_tokens"] as? Int ?? 0,
                                cacheReadTokens: u["cache_read_input_tokens"] as? Int ?? 0,
                                cacheWriteTokens: u["cache_creation_input_tokens"] as? Int ?? 0)
        return CleanupResponse(text: text, usage: usage, milliseconds: elapsed, model: model)
    }

    /// Opens the HTTPS connection ahead of the cleanup call, so the TLS handshake is not paid while the
    /// transcript is already waiting. Fire and forget: the reply is ignored.
    public func prewarm() async {
        var request = URLRequest(url: ClaudeClient.modelsEndpoint)
        request.timeoutInterval = 3
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        _ = try? await session.data(for: request)
    }

    /// One free call to check the key: GET /v1/models.
    public func testConnection() async throws {
        var request = URLRequest(url: ClaudeClient.modelsEndpoint)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch {
            throw DictationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DictationError.badResponse(.anthropic, "no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw DictationError.http(service: .anthropic, status: http.statusCode, message: message)
        }
    }
}
