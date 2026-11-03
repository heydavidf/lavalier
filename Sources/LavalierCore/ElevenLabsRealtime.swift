import Foundation

public struct TranscriptResult: Sendable {
    public let text: String
    public let connectMs: Double
    public let commitToFinalMs: Double
    public let audioSeconds: Double
    public let partialCount: Int
    /// Committed segments joined into `text` (long dictations arrive as several segments).
    public var segmentCount: Int = 1
    /// Segments the server committed by itself (expected 0; more means its auto-commit came first).
    public var serverCommits: Int = 0
}

/// ElevenLabs Scribe v2 Realtime over a WebSocket. One instance per dictation.
/// Audio: 16 kHz mono 16-bit PCM chunks. Manual commit: the last chunk carries commit=true.
///
/// `URLSessionWebSocketTask.receive()` ignores Swift task cancellation and a close frame does nothing while
/// the socket is still connecting, so: the receive loop runs in its own task and feeds a stream whose
/// `next()` honours cancellation, and every timeout calls the hard `URLSessionTask.cancel()`.
public final class ElevenLabsRealtime: @unchecked Sendable {
    public static var endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    public static let sampleRate = 16000
    public static let model = "scribe_v2_realtime"

    /// ElevenLabs ignores a commit with less than 0.3 s of uncommitted audio and answers `commit_throttled`
    /// ("You need at least 0.3s of uncommitted audio before committing"). A quick key tap, or a microphone
    /// that takes most of the hold to start (Bluetooth headsets switching to their call mode), produces
    /// less than that. The final chunk is padded with silence up to this length plus a small margin, so
    /// such a dictation ends as "No speech was heard" instead of failing.
    public static let minimumCommitSeconds = 0.3
    static let minimumCommitBytes = Int((minimumCommitSeconds + 0.02) * Double(sampleRate)) * 2

    /// The last chunk to send with commit=true: `last` (nil if the microphone produced nothing at all),
    /// followed by silence when the whole dictation would otherwise be shorter than the minimum.
    /// `alreadySent` is the number of audio bytes sent before it in this session (all uncommitted).
    public static func finalChunk(_ last: Data?, alreadySent: Int) -> Data {
        var chunk = last ?? Data()
        let missing = minimumCommitBytes - (alreadySent + chunk.count)
        if missing > 0 { chunk.append(Data(count: missing)) }
        return chunk
    }

    /// Longest dictation the app allows (the held key is released automatically after this), and the
    /// socket's lifetime, which adds a margin for the final transcript.
    public static let maximumDictationSeconds: Double = DictationLimits.maximumHoldSeconds
    public static let maximumSessionSeconds: Double = maximumDictationSeconds + 120

    private let apiKey: String
    private let keyterms: [String]
    private let session: URLSession

    public init(apiKey: String, keyterms: [String] = [], session: URLSession = ElevenLabsRealtime.makeSession()) {
        self.apiKey = apiKey
        self.keyterms = Array(keyterms.prefix(PersonalDictionary.maximumKeyterms))
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        // Covers the whole WebSocket session, so it must outlast the longest dictation (it was
        // 120 s, which would have cut every dictation at two minutes).
        config.timeoutIntervalForResource = maximumSessionSeconds
        // The key travels in a request header: keep no URL cache, so it can never be written to Cache.db.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private struct ServerMessage: Sendable {
        let type: String
        let text: String
        let errorMessage: String
    }

    /// Shared flags between the sender, the receiver and the timeout tasks.
    private final class SessionState: @unchecked Sendable {
        private let lock = NSLock()
        private var _handshakeDone = false
        private var _committed = false
        private var _timeout: DictationError?
        // Segment bookkeeping. `expected` counts commits sent (raised before each send, so a
        // fast answer is never mistaken for a server commit); a committed transcript beyond it was the
        // server's own auto-commit and raises it too.
        private var _expected = 0
        private var _segments: [String] = []
        private var _serverCommits = 0
        private var _finalSent = false

        var handshakeDone: Bool { lock.lock(); defer { lock.unlock() }; return _handshakeDone }
        var committed: Bool { lock.lock(); defer { lock.unlock() }; return _committed }
        var timeout: DictationError? { lock.lock(); defer { lock.unlock() }; return _timeout }
        var segments: [String] { lock.lock(); defer { lock.unlock() }; return _segments }
        var serverCommits: Int { lock.lock(); defer { lock.unlock() }; return _serverCommits }
        func markHandshake() { lock.lock(); _handshakeDone = true; lock.unlock() }
        /// Call just before sending a chunk with commit=true.
        func willCommit(final: Bool) {
            lock.lock(); _expected += 1; if final { _finalSent = true }; lock.unlock()
        }
        /// Records a committed segment; true when it was the last one awaited (the key-release commit's).
        func addSegment(_ text: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _segments.append(text)
            if _segments.count > _expected { _expected = _segments.count; _serverCommits += 1 }
            let done = _finalSent && _segments.count >= _expected
            if done { _committed = true }
            return done
        }
        /// Returns true if this call set the timeout (first one wins).
        func markTimeout(_ e: DictationError) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if _timeout == nil { _timeout = e; return true }
            return false
        }
    }

    /// Single consumer of the message stream, handed from the handshake to the receiver task.
    private final class MessageReader: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<ServerMessage, Error>.AsyncIterator
        init(_ stream: AsyncThrowingStream<ServerMessage, Error>) { iterator = stream.makeAsyncIterator() }
        func next() async throws -> ServerMessage? { try await iterator.next() }
    }

    private static func parse(_ message: URLSessionWebSocketTask.Message) throws -> ServerMessage {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: throw DictationError.badResponse(.elevenLabs, "unknown frame")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["message_type"] as? String else {
            throw DictationError.badResponse(.elevenLabs, String(data: data.prefix(200), encoding: .utf8) ?? "binary")
        }
        let text = json["text"] as? String ?? ""
        let err = (json["error"] as? String) ?? (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? ""
        return ServerMessage(type: type, text: text, errorMessage: err)
    }

    private static func mapError(_ error: Error, state: SessionState) -> DictationError {
        if let t = state.timeout { return t }
        if let e = error as? DictationError { return e }
        if let e = error as? URLError, e.code == .notConnectedToInternet { return .offline }
        return .network(error.localizedDescription)
    }

    /// Receive loop in its own task; the stream ends with the first error (including a cancelled socket).
    private static func messageStream(_ task: URLSessionWebSocketTask, state: SessionState) -> AsyncThrowingStream<ServerMessage, Error> {
        AsyncThrowingStream { continuation in
            let t = Task.detached {
                while true {
                    do {
                        let m = try await task.receive()
                        continuation.yield(try parse(m))
                    } catch {
                        continuation.finish(throwing: mapError(error, state: state))
                        return
                    }
                }
            }
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    private func makeTask() -> URLSessionWebSocketTask {
        var components = URLComponents(url: ElevenLabsRealtime.endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "model_id", value: ElevenLabsRealtime.model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "language_code", value: "en"),
        ]
        for term in keyterms { items.append(URLQueryItem(name: "keyterms", value: term)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return session.webSocketTask(with: request)
    }

    private static func chunkMessage(_ pcm: Data, commit: Bool) -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "sample_rate": sampleRate,
            "commit": commit,
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }

    private static func send(_ task: URLSessionWebSocketTask, _ text: String, state: SessionState) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw mapError(error, state: state)
        }
    }

    /// Streams `audio` and returns the committed transcript. The stream must finish when the key is released.
    public func transcribe(audio: AsyncStream<Data>,
                           connectTimeout: Double = 3,
                           transcriptTimeout: Double = 5,
                           segmentMinimumSeconds: Double = SegmentCommitPlanner.defaultMinimumSeconds,
                           segmentMaximumSeconds: Double = SegmentCommitPlanner.defaultMaximumSeconds,
                           onPartial: (@Sendable (String) -> Void)? = nil) async throws -> TranscriptResult {
        let task = makeTask()
        let state = SessionState()
        let connectStarted = nowMs()
        task.resume()
        let reader = MessageReader(ElevenLabsRealtime.messageStream(task, state: state))
        defer { task.cancel() }

        // 1. Handshake: wait for session_started; the timeout hard-cancels the socket.
        let handshakeTimer = Task {
            try await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
            if !state.handshakeDone, state.markTimeout(.connectTimeout) { task.cancel() }
        }
        do {
            try await withTimeout(seconds: connectTimeout + 1, error: .connectTimeout) {
                while let m = try await reader.next() {
                    if m.type == "session_started" { return }
                    if DictationError.elevenLabsErrorTypes.contains(m.type) {
                        throw DictationError.elevenLabs(type: m.type, message: m.errorMessage)
                    }
                }
                throw state.timeout ?? DictationError.badResponse(.elevenLabs, "connection closed before session_started")
            }
        } catch {
            handshakeTimer.cancel()
            throw state.timeout ?? ElevenLabsRealtime.mapError(error, state: state)
        }
        handshakeTimer.cancel()
        state.markHandshake()
        let connectMs = nowMs() - connectStarted

        // 2. Send audio while receiving partials; the last chunk commits. A timer started when the audio
        //    stream ends hard-cancels the socket if the committed transcript does not arrive in time.
        enum Outcome: Sendable { case sent(bytes: Int, commitAt: Double); case committed(text: String, at: Double, partials: Int) }
        let partialBox = PartialBox()
        let timerBox = TaskBox()
        defer { timerBox.cancel() }

        do {
            return try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    var pending: Data?
                    var bytes = 0
                    // Commit a segment at a pause every 20 to 30 s, before the server's own ~36 s auto-commit.
                    var planner = SegmentCommitPlanner(sampleRate: Self.sampleRate,
                                                       minimumSeconds: segmentMinimumSeconds,
                                                       maximumSeconds: segmentMaximumSeconds)
                    for await chunk in audio {
                        if let prev = pending {
                            let commit = planner.add(prev)
                            if commit { state.willCommit(final: false) }
                            try await Self.send(task, Self.chunkMessage(prev, commit: commit), state: state)
                            bytes += prev.count
                        }
                        pending = chunk
                    }
                    // Audio finished (key released): start the transcript deadline before the final send,
                    // so a stalled send is covered too.
                    timerBox.set(Task {
                        try await Task.sleep(nanoseconds: UInt64(transcriptTimeout * 1_000_000_000))
                        if !state.committed, state.markTimeout(.transcriptTimeout) { task.cancel() }
                    })
                    // Pad with silence if the last segment is shorter than the server's commit minimum (or empty).
                    let last = Self.finalChunk(pending, alreadySent: planner.uncommittedBytes)
                    state.willCommit(final: true)
                    try await Self.send(task, Self.chunkMessage(last, commit: true), state: state)
                    bytes += last.count
                    return .sent(bytes: bytes, commitAt: nowMs())
                }
                group.addTask {
                    while let m = try await reader.next() {
                        switch m.type {
                        case "partial_transcript":
                            partialBox.increment()
                            // Partials cover the current segment only; show what came before as well.
                            onPartial?(TranscriptSegments.join(state.segments + [m.text]))
                        case "committed_transcript":
                            // Only the plain event: `_with_timestamps` repeats a segment when timestamps
                            // are requested (they are not), and must not count twice.
                            if state.addSegment(m.text) {
                                return .committed(text: TranscriptSegments.join(state.segments), at: nowMs(), partials: partialBox.count)
                            }
                        case let t where DictationError.elevenLabsErrorTypes.contains(t):
                            throw DictationError.elevenLabs(type: t, message: m.errorMessage)
                        default:
                            continue
                        }
                    }
                    throw state.timeout ?? DictationError.badResponse(.elevenLabs, "connection closed before the transcript")
                }

                var sentBytes = 0
                var commitAt: Double?
                var committed: (String, Double, Int)?
                while let outcome = try await group.next() {
                    switch outcome {
                    case .sent(let bytes, let at):
                        sentBytes = bytes
                        commitAt = at
                    case .committed(let text, let at, let partials):
                        committed = (text, at, partials)
                    }
                    if committed != nil && commitAt != nil { break }
                }
                group.cancelAll()
                guard let (text, at, partials) = committed, let commit = commitAt else {
                    throw state.timeout ?? DictationError.transcriptTimeout
                }
                return TranscriptResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                        connectMs: connectMs,
                                        commitToFinalMs: max(0, at - commit),
                                        audioSeconds: Double(sentBytes) / 2 / Double(Self.sampleRate),
                                        partialCount: partials,
                                        segmentCount: state.segments.count,
                                        serverCommits: state.serverCommits)
            }
        } catch {
            throw state.timeout ?? ElevenLabsRealtime.mapError(error, state: state)
        }
    }
}

final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    func set(_ t: Task<Void, Error>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); lock.unlock() }
}

// MARK: - Subscription / credits (free read)

public struct ElevenLabsSubscription: Sendable, Equatable {
    public let tier: String
    public let creditsUsed: Int
    public let creditLimit: Int
    public let nextReset: Date?
    public let status: String

    public init(tier: String, creditsUsed: Int, creditLimit: Int, nextReset: Date?, status: String) {
        self.tier = tier
        self.creditsUsed = creditsUsed
        self.creditLimit = creditLimit
        self.nextReset = nextReset
        self.status = status
    }

    public var creditsRemaining: Int { max(0, creditLimit - creditsUsed) }
    public var fractionRemaining: Double { creditLimit > 0 ? Double(creditsRemaining) / Double(creditLimit) : 0 }
}

public enum ElevenLabsAccount {
    public static var subscriptionEndpoint = URL(string: "https://api.elevenlabs.io/v1/user/subscription")!

    /// Like the other sessions, no URL cache: the key travels in a request header.
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    public static func fetchSubscription(apiKey: String, session: URLSession = ElevenLabsAccount.session) async throws -> ElevenLabsSubscription {
        var request = URLRequest(url: subscriptionEndpoint)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch let error as URLError where error.code == .notConnectedToInternet {
            throw DictationError.offline
        } catch {
            throw DictationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DictationError.badResponse(.elevenLabs, "no HTTP response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let detail = ((json?["detail"] as? [String: Any])?["message"] as? String) ?? (json?["detail"] as? String) ?? ""
            throw DictationError.http(service: .elevenLabs, status: http.statusCode, message: detail)
        }
        guard let j = json else { throw DictationError.badResponse(.elevenLabs, "not JSON") }
        let reset = (j["next_character_count_reset_unix"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return ElevenLabsSubscription(tier: j["tier"] as? String ?? "?",
                                      creditsUsed: j["character_count"] as? Int ?? 0,
                                      creditLimit: j["character_limit"] as? Int ?? 0,
                                      nextReset: reset,
                                      status: j["status"] as? String ?? "?")
    }
}
