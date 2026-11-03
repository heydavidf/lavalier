import Foundation
import Network
import XCTest
@testable import LavalierCore

/// Cutoff bug: long dictations came back as only their first ~36 s, because ElevenLabs commits a
/// segment by itself after about 36 s of audio and the client returned the first committed transcript.
final class CutoffTests: XCTestCase {
    static let rate = 16000

    /// `seconds` of 16-bit mono PCM: a loud square wave, or digital silence.
    static func pcm(seconds: Double, loud: Bool) -> Data {
        let n = Int(seconds * Double(rate))
        var d = Data(count: n * 2)
        if loud {
            d.withUnsafeMutableBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<n { s[i] = (i / 20) % 2 == 0 ? 8000 : -8000 }
            }
        }
        return d
    }

    /// Feeds `audio` in 64 ms chunks (microphone-like) and returns the times, in seconds, at which it committed.
    static func commitTimes(_ audio: Data, planner: inout SegmentCommitPlanner) -> [Double] {
        var times: [Double] = []
        var sent = 0
        for chunk in AudioChunking.chunks(audio, bytesPerChunk: 2048) {
            sent += chunk.count
            if planner.add(chunk) { times.append(Double(sent) / 2 / Double(rate)) }
        }
        return times
    }

    func testContinuousSpeechIsCommittedEveryThirtySecondsBeforeTheServerDoes() {
        var planner = SegmentCommitPlanner()
        let times = Self.commitTimes(Self.pcm(seconds: 100, loud: true), planner: &planner)
        XCTAssertEqual(times.count, 3)
        for (i, t) in times.enumerated() { XCTAssertEqual(t, Double(i + 1) * 30, accuracy: 0.1) }
        XCTAssertLessThan(planner.uncommittedSeconds, 36, "never reaches the server's ~36 s auto-commit")
    }

    func testCommitsAtTheFirstPauseAfterTenSeconds() {
        var planner = SegmentCommitPlanner()
        var audio = Self.pcm(seconds: 6, loud: true)
        audio.append(Self.pcm(seconds: 1, loud: false))   // a pause before 10 s: too early, ignored
        audio.append(Self.pcm(seconds: 7, loud: true))
        audio.append(Self.pcm(seconds: 1, loud: false))   // a pause at 14 s: commit half a second in
        audio.append(Self.pcm(seconds: 10, loud: true))
        let times = Self.commitTimes(audio, planner: &planner)
        XCTAssertEqual(times.count, 1)
        XCTAssertGreaterThan(times[0], 14.4)
        XCTAssertLessThan(times[0], 15.0)
    }

    /// A short gap between words is not a pause, until the segment nears the limit.
    func testShortGapsBetweenWordsOnlyCountNearTheLimit() {
        var planner = SegmentCommitPlanner()
        var audio = Data()
        for _ in 0..<10 {   // 3 s of words, then a 0.3 s gap: 33 s in all
            audio.append(Self.pcm(seconds: 3, loud: true))
            audio.append(Self.pcm(seconds: 0.3, loud: false))
        }
        let times = Self.commitTimes(audio, planner: &planner)
        XCTAssertEqual(times.count, 1)
        XCTAssertGreaterThan(times[0], 25, "no commit at a word gap before 25 s")
        XCTAssertLessThan(times[0], 30, "a word gap after 25 s instead of a cut at 30 s")
    }

    func testFiveMinutesAreSplitIntoSegmentsUnderTheServerLimit() {
        var planner = SegmentCommitPlanner()
        var audio = Data()
        for _ in 0..<30 {   // 30 × (9 s speech + 1 s pause) = 300 s
            audio.append(Self.pcm(seconds: 9, loud: true))
            audio.append(Self.pcm(seconds: 1, loud: false))
        }
        let times = Self.commitTimes(audio, planner: &planner)
        let boundaries = [0.0] + times + [300.0]
        for (a, b) in zip(boundaries, boundaries.dropFirst()) { XCTAssertLessThanOrEqual(b - a, 30.01) }
        XCTAssertGreaterThanOrEqual(times.count, 9)
    }

    func testSegmentsAreJoinedWithSingleSpaces() {
        XCTAssertEqual(TranscriptSegments.join(["One two.", " Three. ", "", "Four"]), "One two. Three. Four")
        XCTAssertEqual(TranscriptSegments.join([]), "")
    }

    func testCleanupAllowanceGrowsWithTheDictation() {
        let fiveMinutes = Array(repeating: "word", count: 900).joined(separator: " ")
        XCTAssertGreaterThanOrEqual(Cleanup.maxTokens(for: fiveMinutes), 2400, "900 words need about 1,200 tokens")
        XCTAssertEqual(Cleanup.maxTokens(for: "a short note"), 1024)
        XCTAssertEqual(Cleanup.maxTokens(for: Array(repeating: "w", count: 10_000).joined(separator: " ")), 8192)
    }

    func testLimitsAllowAFiveMinuteDictation() {
        XCTAssertGreaterThanOrEqual(DictationLimits.maximumHoldSeconds, 300)
        XCTAssertGreaterThan(ElevenLabsRealtime.maximumSessionSeconds, DictationLimits.maximumHoldSeconds)
        XCTAssertEqual(DictationLimits.processingDeadline(heldSeconds: 2), 25.1, accuracy: 0.001)
        XCTAssertEqual(DictationLimits.processingDeadline(heldSeconds: 300), 40, accuracy: 0.001)
    }

    // MARK: Against a local stand-in for the ElevenLabs realtime server

    private var savedEndpoint = ElevenLabsRealtime.endpoint
    override func setUp() { savedEndpoint = ElevenLabsRealtime.endpoint }
    override func tearDown() { ElevenLabsRealtime.endpoint = savedEndpoint }

    func testEverySegmentOfALongDictationIsReturned() async throws {
        let server = try FakeScribeServer(autoCommitSeconds: 36)
        try await server.start()
        defer { server.stop() }
        ElevenLabsRealtime.endpoint = URL(string: "ws://127.0.0.1:\(server.port)/")!
        let stt = ElevenLabsRealtime(apiKey: "test")
        let result = try await stt.transcribe(audio: AudioChunking.stream(Self.pcm(seconds: 100, loud: true), paced: false))
        // Client commits at about 30, 60 and 90 s (the first 256 ms chunk past each), then on release at 100 s.
        XCTAssertEqual(result.text, "s1(30s) s2(30s) s3(30s) s4(9s)")
        XCTAssertEqual(result.segmentCount, 4)
        XCTAssertEqual(result.serverCommits, 0)
        XCTAssertEqual(result.audioSeconds, 100, accuracy: 0.1)
    }

    /// The bug itself: with no client commits, the server auto-commits at 36 s; the old client returned "s1" only.
    func testSegmentsTheServerCommitsByItselfAreKept() async throws {
        let server = try FakeScribeServer(autoCommitSeconds: 36)
        try await server.start()
        defer { server.stop() }
        ElevenLabsRealtime.endpoint = URL(string: "ws://127.0.0.1:\(server.port)/")!
        let stt = ElevenLabsRealtime(apiKey: "test")
        let result = try await stt.transcribe(audio: AudioChunking.stream(Self.pcm(seconds: 100, loud: true), paced: false),
                                              segmentMinimumSeconds: 10_000, segmentMaximumSeconds: 10_000)
        XCTAssertEqual(result.segmentCount, 3)
        XCTAssertEqual(result.serverCommits, 2)
        XCTAssertTrue(result.text.hasPrefix("s1("), result.text)
        XCTAssertTrue(result.text.contains("s3("), "the segment after the key release is included: \(result.text)")
    }

    func testAShortDictationIsStillOneSegment() async throws {
        let server = try FakeScribeServer(autoCommitSeconds: 36)
        try await server.start()
        defer { server.stop() }
        ElevenLabsRealtime.endpoint = URL(string: "ws://127.0.0.1:\(server.port)/")!
        let stt = ElevenLabsRealtime(apiKey: "test")
        let result = try await stt.transcribe(audio: AudioChunking.stream(Self.pcm(seconds: 4, loud: true), paced: false))
        XCTAssertEqual(result.text, "s1(4s)")
        XCTAssertEqual(result.segmentCount, 1)
    }
}

/// Minimal WebSocket server that behaves like ElevenLabs realtime for commits: `session_started` on connect,
/// a `committed_transcript` "sN(Ls)" for each chunk with commit=true, and an auto-commit of its own after
/// `autoCommitSeconds` of uncommitted audio.
final class FakeScribeServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-scribe")
    private let autoCommitBytes: Int
    private var connections: [NWConnection] = []

    init(autoCommitSeconds: Double) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Loopback only, so the test never accepts connections from the network (and never triggers a firewall prompt).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        autoCommitBytes = Int(autoCommitSeconds * 16000) * 2
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { c.resume() }
                case .failed(let e): if once.claim() { c.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }

    private func serve(_ conn: NWConnection) {
        connections.append(conn)
        var uncommitted = 0
        var segment = 0
        func send(_ object: [String: Any]) {
            let data = try! JSONSerialization.data(withJSONObject: object)
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
        func commit() {
            segment += 1
            let seconds = Int((Double(uncommitted) / 2 / 16000).rounded())
            uncommitted = 0
            send(["message_type": "committed_transcript", "text": "s\(segment)(\(seconds)s)"])
        }
        func receive() {
            conn.receiveMessage { data, _, _, error in
                guard error == nil, let data,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                if json["message_type"] as? String == "input_audio_chunk" {
                    let audio = Data(base64Encoded: json["audio_base_64"] as? String ?? "") ?? Data()
                    if json["commit"] as? Bool == true {
                        uncommitted += audio.count
                        commit()
                    } else {
                        // The server's own commit: at the limit, mid-chunk (the rest starts the next segment).
                        let room = self.autoCommitBytes - uncommitted
                        if audio.count >= room {
                            uncommitted += room
                            commit()
                            uncommitted = audio.count - room
                        } else {
                            uncommitted += audio.count
                        }
                        if !audio.isEmpty { send(["message_type": "partial_transcript", "text": "…"]) }
                    }
                }
                receive()
            }
        }
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                send(["message_type": "session_started", "session_id": "test"])
                receive()
            }
        }
        conn.start(queue: queue)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
