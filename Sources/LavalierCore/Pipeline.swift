import Foundation

public struct PipelineConfig: Sendable {
    public var cleanupEnabled = true
    public var sendKeyterms = false
    public var connectTimeout = 3.0
    public var transcriptTimeout = 5.0
    public var cleanupTimeout = 6.0
    public var minimumWordsForCleanup = Cleanup.minimumWords
    public var retryTransient = true
    /// Start the cleanup at key release on the live transcript (see `CleanupSpeculation`).
    public var speculativeCleanup = true
    /// Identical cleanup requests sent at once; the first answer wins. Off (1) by default: on 3 November 2026
    /// two copies on separate connections were no faster over 12 runs and slow answers hit both copies at
    /// once. Kept for measurement with `lavalier-cli --parallel 2`.
    public var parallelCleanupRequests = 1

    public init() {}
}

public struct DictationOutcome: Sendable {
    public let raw: String
    public let cleaned: String?
    public let finalText: String
    public let audioSeconds: Double
    public let connectMs: Double
    public let sttMs: Double
    public let claudeMs: Double?
    public let claudeUsage: ClaudeUsage?
    public let cleanupSkippedReason: String?
    public let cleanupError: DictationError?
    public let partialCount: Int
    /// Key release (stream finished) to final text ready, in ms.
    public let totalMs: Double
    /// Claude requests sent for this dictation, including parallel copies and a discarded speculative start.
    public var claudeRequests = 0
    /// "hit" (the cleanup started at release was used), "miss" (discarded, rerun on the committed text) or nil.
    public var speculation: String?
    /// The live transcript the speculative cleanup started on (test harness only; the app does not log it).
    public var speculativeInput: String?

    public var usedRawBecauseCleanupFailed: Bool { cleanupError != nil }

    /// Upper-bound billing estimate: every request is charged the winning request's tokens.
    public var billedUsageEstimate: ClaudeUsage? {
        guard let u = claudeUsage, claudeRequests > 1 else { return claudeUsage }
        return ClaudeUsage(inputTokens: u.inputTokens * claudeRequests, outputTokens: u.outputTokens * claudeRequests,
                           cacheReadTokens: u.cacheReadTokens * claudeRequests, cacheWriteTokens: u.cacheWriteTokens * claudeRequests)
    }
}

/// One dictation: audio stream in, final text out. The app inserts the text; the CLI prints it.
public final class DictationPipeline: Sendable {
    private let keys: KeyProvider
    private let dictionary: @Sendable () -> [String]
    private let config: PipelineConfig
    /// One HTTPS connection per parallel cleanup copy, so the copies are independent draws:
    /// two requests multiplexed on one connection measured no faster than one.
    private let claudeSessions: [URLSession]
    private let elevenSession: URLSession

    public init(keys: KeyProvider, dictionary: @escaping @Sendable () -> [String], config: PipelineConfig = PipelineConfig()) {
        self.keys = keys
        self.dictionary = dictionary
        self.config = config
        self.claudeSessions = (0..<max(1, config.parallelCleanupRequests)).map { _ in ClaudeClient.makeSession() }
        self.elevenSession = ElevenLabsRealtime.makeSession()
    }

    /// Opens the connection and streams audio. `audio` must finish when the key is released.
    public func run(audio: AsyncStream<Data>, onPartial: (@Sendable (String) -> Void)? = nil) async throws -> DictationOutcome {
        let elevenKey = try keys.key(for: .elevenLabs)
        let terms = dictionary()
        let stt = ElevenLabsRealtime(apiKey: elevenKey, keyterms: config.sendKeyterms ? terms : [], session: elevenSession)

        let prompt = Cleanup.systemPrompt(dictionary: terms)
        let speculativeKey: String? = (config.cleanupEnabled && config.speculativeCleanup) ? try? keys.key(for: .anthropic) : nil

        // The live transcript, kept so the cleanup can start on it the moment the key is released.
        let latestPartial = LatestBox<String>()
        let partialHandler: @Sendable (String) -> Void = { text in
            latestPartial.set(text)
            onPartial?(text)
        }
        let speculation = LatestBox<(input: String, task: Task<CleanupResponse, Error>)>()

        // Release time is when the audio stream finishes; wrap the stream to observe that moment.
        let releaseBox = TimeBox()
        let observed = AsyncStream<Data> { continuation in
            let t = Task {
                for await chunk in audio { continuation.yield(chunk) }
                releaseBox.set(nowMs())
                if let key = speculativeKey, let partial = latestPartial.value,
                   Cleanup.shouldClean(partial, minimumWords: self.config.minimumWordsForCleanup) {
                    let task = Task { try await self.cleanupWithRetry(apiKey: key, raw: partial, prompt: prompt) }
                    speculation.set((partial, task))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in t.cancel() }
        }

        let transcript: TranscriptResult
        do {
            transcript = try await stt.transcribe(audio: observed,
                                                  connectTimeout: config.connectTimeout,
                                                  transcriptTimeout: config.transcriptTimeout,
                                                  onPartial: partialHandler)
        } catch {
            speculation.value?.task.cancel()
            throw error
        }
        let raw = transcript.text
        let releaseAt = releaseBox.value ?? nowMs()

        var cleaned: String?
        var claudeMs: Double?
        var usage: ClaudeUsage?
        var skipped: String?
        var cleanupError: DictationError?
        var requests = 0
        var speculationResult: String?

        // A speculative start whose words differ from the committed transcript is discarded.
        let started = speculation.value
        var reusable: Task<CleanupResponse, Error>?
        if let started {
            requests += config.parallelCleanupRequests
            if CleanupSpeculation.sameWords(started.input, raw) {
                reusable = started.task
            } else {
                started.task.cancel()
                speculationResult = "miss"
            }
        }

        if raw.isEmpty {
            skipped = "empty transcript"
        } else if !config.cleanupEnabled {
            skipped = "cleanup disabled"
        } else if !Cleanup.shouldClean(raw, minimumWords: config.minimumWordsForCleanup) {
            skipped = "under \(config.minimumWordsForCleanup) words"
        } else {
            do {
                var response: CleanupResponse?
                if let reusable {
                    // If the speculative call failed, fall through to a normal cleanup of the committed text.
                    if let r = try? await reusable.value {
                        response = r
                        speculationResult = "hit"
                    } else {
                        speculationResult = "miss"
                    }
                }
                if response == nil {
                    let anthropicKey = try keys.key(for: .anthropic)
                    requests += config.parallelCleanupRequests
                    response = try await cleanupWithRetry(apiKey: anthropicKey, raw: raw, prompt: prompt)
                }
                guard let response else { throw DictationError.badResponse(.anthropic, "no response") }
                cleaned = response.text.isEmpty ? nil : response.text
                claudeMs = response.milliseconds
                usage = response.usage
                if cleaned == nil { cleanupError = .badResponse(.anthropic, "empty text") }
            } catch let e as DictationError {
                cleanupError = e
            } catch {
                cleanupError = .network(error.localizedDescription)
            }
        }
        if let reusable, speculationResult == nil { reusable.cancel() }

        let finalText = cleaned ?? raw
        var outcome = DictationOutcome(raw: raw, cleaned: cleaned, finalText: finalText,
                                       audioSeconds: transcript.audioSeconds, connectMs: transcript.connectMs,
                                       sttMs: transcript.commitToFinalMs, claudeMs: claudeMs, claudeUsage: usage,
                                       cleanupSkippedReason: skipped, cleanupError: cleanupError,
                                       partialCount: transcript.partialCount,
                                       totalMs: max(0, nowMs() - releaseAt))
        outcome.claudeRequests = requests
        outcome.speculation = speculationResult
        outcome.speculativeInput = started?.input
        return outcome
    }

    /// Call when the key goes down: warms the Claude connection while the user is still speaking.
    public func prewarm() async {
        guard config.cleanupEnabled, let key = try? keys.key(for: .anthropic) else { return }
        await withTaskGroup(of: Void.self) { group in
            for session in claudeSessions { group.addTask { await ClaudeClient(apiKey: key, session: session).prewarm() } }
        }
    }

    private func cleanupWithRetry(apiKey: String, raw: String, prompt: String) async throws -> CleanupResponse {
        // Longer dictations take longer to clean up.
        let timeout = config.cleanupTimeout + Double(Cleanup.wordCount(raw)) * Cleanup.timeoutSecondsPerWord
        // Identical requests at once, first answer wins.
        let clients = claudeSessions.map { ClaudeClient(apiKey: apiKey, session: $0) }
        do {
            return try await withTimeout(seconds: timeout, error: .cleanupTimeout) {
                try await firstSuccess(count: clients.count) { i in try await clients[i].cleanup(raw: raw, systemPrompt: prompt, timeout: timeout) }
            }
        } catch let e as DictationError where e.isTransient && config.retryTransient && e != .cleanupTimeout {
            return try await withTimeout(seconds: timeout, error: .cleanupTimeout) {
                try await firstSuccess(count: clients.count) { i in try await clients[i].cleanup(raw: raw, systemPrompt: prompt, timeout: timeout) }
            }
        }
    }
}

final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Double?
    var value: Double? { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ x: Double) { lock.lock(); v = x; lock.unlock() }
}
