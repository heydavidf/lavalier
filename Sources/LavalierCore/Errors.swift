import Foundation

/// Every failure the app can show. `userMessage` is the plain-language text for the menu.
public enum DictationError: Error, Equatable {
    public enum Service: String, Codable, Sendable {
        case elevenLabs = "ElevenLabs"
        case anthropic = "Anthropic"
    }

    case missingKey(Service)
    case offline
    case connectTimeout
    case transcriptTimeout
    case cleanupTimeout
    case elevenLabs(type: String, message: String)
    case http(service: Service, status: Int, message: String)
    case network(String)
    case badResponse(Service, String)
    case insertionFailed(String)
    case permissionMissing(String)
    case audio(String)

    public var userMessage: String {
        switch self {
        case .missingKey(let s):
            return "\(s.rawValue) key is missing. Open Settings and paste it."
        case .offline:
            return "Offline, dictation unavailable."
        case .connectTimeout:
            return "Could not reach ElevenLabs in time. Check the connection and try again."
        case .transcriptTimeout:
            return "ElevenLabs did not return the transcript in time. Try again."
        case .cleanupTimeout:
            return "Claude took too long; the raw transcript was used instead."
        case .elevenLabs(let type, let message):
            switch type {
            case "quota_exceeded":
                return "ElevenLabs credits are used up for this month."
            case "commit_throttled":
                // Sent when less than 0.3 s of audio was committed; not a rate limit despite the name.
                return "That was too short to transcribe. Hold the key while you speak."
            case "rate_limited", "resource_exhausted", "queue_overflow":
                return "ElevenLabs is busy or rate limiting. Try again in a moment."
            case "session_time_limit_exceeded":
                return "That dictation was too long for one session. Release the key sooner and try again."
            case "insufficient_audio_activity":
                return "No speech was heard."
            case "auth_error", "authentication_error", "invalid_api_key", "unauthorized":
                return "ElevenLabs rejected the key. Check Settings."
            default:
                return "ElevenLabs error: \(message.isEmpty ? type : message)"
            }
        case .http(let service, let status, let message):
            switch (service, status) {
            case (_, 401), (_, 403):
                return "\(service.rawValue) rejected the key. Check Settings."
            case (.anthropic, 429):
                return "Claude is rate limiting; the raw transcript was used instead."
            case (.elevenLabs, 429):
                return "ElevenLabs is rate limiting. Try again in a moment."
            case (_, 500...599):
                return "\(service.rawValue) had a server problem (\(status)). Try again."
            default:
                return "\(service.rawValue) error \(status): \(message)"
            }
        case .network(let detail):
            return "Network problem: \(detail)"
        case .badResponse(let service, let detail):
            return "\(service.rawValue) sent an unexpected reply: \(detail)"
        case .insertionFailed(let detail):
            return "Could not insert the text: \(detail). Use Copy last dictation."
        case .permissionMissing(let name):
            return "\(name) permission is missing. Open Permissions."
        case .audio(let detail):
            return "Microphone problem: \(detail)"
        }
    }

    /// Transient failures get one automatic retry.
    public var isTransient: Bool {
        switch self {
        case .connectTimeout, .transcriptTimeout, .cleanupTimeout, .network:
            return true
        case .elevenLabs(let type, _):
            // Not commit_throttled: replaying the same too-short recording fails the same way.
            return ["rate_limited", "resource_exhausted", "queue_overflow"].contains(type)
        case .http(_, let status, _):
            return status == 429 || (500...599).contains(status) || status == 408
        default:
            return false
        }
    }

    /// Message types the ElevenLabs realtime endpoint can send that mean failure.
    public static let elevenLabsErrorTypes: Set<String> = [
        "error", "auth_error", "authentication_error", "quota_exceeded", "rate_limited", "commit_throttled",
        "session_time_limit_exceeded", "insufficient_audio_activity", "chunk_size_exceeded", "queue_overflow",
        "resource_exhausted", "invalid_request", "input_error", "transcriber_error", "base_model_transcriber_error",
    ]
}

/// Run `operation` and fail with `error` if it takes longer than `seconds`.
public func withTimeout<T: Sendable>(seconds: Double, error: DictationError,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw error
        }
        guard let first = try await group.next() else { throw error }
        group.cancelAll()
        return first
    }
}

public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
