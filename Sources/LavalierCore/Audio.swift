import Foundation

/// Minimal reader for 16-bit PCM WAV files (synthetic test audio for lavalier-cli).
public struct WAVFile {
    public let sampleRate: Int
    public let channels: Int
    public let pcm: Data

    public var seconds: Double { Double(pcm.count) / 2 / Double(channels) / Double(sampleRate) }

    public init(data: Data) throws {
        guard data.count > 12, String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            throw DictationError.audio("not a WAV file")
        }
        var offset = 12
        var sampleRate = 0, channels = 0, bits = 0
        var pcm: Data?
        while offset + 8 <= data.count {
            let id = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(data.readUInt32LE(at: offset + 4))
            let body = offset + 8
            if id == "fmt " {
                channels = Int(data.readUInt16LE(at: body + 2))
                sampleRate = Int(data.readUInt32LE(at: body + 4))
                bits = Int(data.readUInt16LE(at: body + 14))
            } else if id == "data" {
                pcm = data.subdata(in: body..<min(body + size, data.count))
            }
            offset = body + size + (size % 2)
        }
        guard bits == 16, let p = pcm, sampleRate > 0, channels > 0 else {
            throw DictationError.audio("need 16-bit PCM WAV; got \(bits)-bit")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.pcm = p
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    /// Mono 16 kHz PCM, converting by simple decimation/duplication if needed (test audio only).
    public func pcm16kMono() -> Data {
        if sampleRate == 16000 && channels == 1 { return pcm }
        let frames = pcm.count / 2 / channels
        var out = Data()
        out.reserveCapacity(frames * 2)
        let ratio = Double(sampleRate) / 16000.0
        let outFrames = Int(Double(frames) / ratio)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<outFrames {
                let src = min(frames - 1, Int(Double(i) * ratio))
                var acc = 0
                for c in 0..<channels { acc += Int(samples[src * channels + c]) }
                var s = Int16(clamping: acc / channels)
                withUnsafeBytes(of: &s) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset]) | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16) | (UInt32(self[startIndex + offset + 3]) << 24)
    }
}

public enum AudioChunking {
    /// 256 ms at 16 kHz, matching the ElevenLabs cookbook.
    public static let samplesPerChunk = 4096
    public static let bytesPerChunk = samplesPerChunk * 2

    public static func chunks(_ pcm: Data, bytesPerChunk: Int = AudioChunking.bytesPerChunk) -> [Data] {
        stride(from: 0, to: pcm.count, by: bytesPerChunk).map { pcm.subdata(in: $0..<min($0 + bytesPerChunk, pcm.count)) }
    }

    /// Yields chunks at real-time pace (as a microphone would), or as fast as possible when paced is false.
    public static func stream(_ pcm: Data, paced: Bool, sampleRate: Int = 16000) -> AsyncStream<Data> {
        let parts = chunks(pcm)
        return AsyncStream { continuation in
            let task = Task {
                for part in parts {
                    if Task.isCancelled { break }
                    continuation.yield(part)
                    if paced {
                        let seconds = Double(part.count) / 2 / Double(sampleRate)
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
