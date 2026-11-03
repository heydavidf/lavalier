import Foundation

/// Cutoff bug: long dictations came back as only their first 30-odd seconds.
///
/// ElevenLabs realtime commits a segment by itself after about 36 s of uncommitted audio, even with
/// `commit_strategy=manual` ("the model automatically commits after approximately 36 seconds of accumulated
/// audio"; "A session can have multiple committed transcripts", ElevenLabs realtime commit-strategy guide,
/// read 3 November 2026). The client returned the first committed transcript and dropped the rest.
///
/// The client now commits by itself before the server does, so it knows how many segments to wait for.
/// A commit in the middle of a word garbles it ("The- Mm-hmm ... main risk", measured), so it commits at a
/// pause: from `minimumSeconds` on, at the first half-second that is clearly quieter than the segment's
/// speech (a pause between sentences); from `relaxedSeconds` on, at any short gap between words; and at
/// the latest at `maximumSeconds`. The guide recommends committing every 20 to 30 s and "during silence
/// periods". The final segment is committed on key release, as before.
public struct SegmentCommitPlanner: Sendable {
    public static let defaultMinimumSeconds = 10.0
    public static let defaultMaximumSeconds = 30.0
    /// From this long on, a short gap between words is good enough.
    public static let relaxedSeconds = 25.0
    /// A pause: this long, with loudness under this fraction of the segment's average.
    public static let pauseSeconds = 0.5
    public static let pauseFraction = 0.15
    /// A gap between words, accepted after `relaxedSeconds`.
    public static let gapSeconds = 0.25
    public static let gapFraction = 0.3

    public let sampleRate: Int
    public let minimumSeconds: Double
    public let maximumSeconds: Double

    /// Bytes sent since the last commit (all uncommitted on the server).
    public private(set) var uncommittedBytes = 0
    /// Commits this planner asked for (not counting the final one on key release).
    public private(set) var commits = 0

    private var segmentSumSquares = 0.0
    private var segmentSamples = 0
    private var window: [(samples: Int, sumSquares: Double)] = []
    private var windowSamples = 0
    private var windowSumSquares = 0.0

    public init(sampleRate: Int = 16000,
                minimumSeconds: Double = SegmentCommitPlanner.defaultMinimumSeconds,
                maximumSeconds: Double = SegmentCommitPlanner.defaultMaximumSeconds) {
        self.sampleRate = sampleRate
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = max(minimumSeconds, maximumSeconds)
    }

    public var uncommittedSeconds: Double { Double(uncommittedBytes) / 2 / Double(sampleRate) }

    /// Call for each 16-bit mono PCM chunk just before it is sent. True means: send this chunk with commit=true.
    public mutating func add(_ chunk: Data) -> Bool {
        let (samples, sumSquares) = SegmentCommitPlanner.energy(chunk)
        uncommittedBytes += chunk.count
        segmentSamples += samples
        segmentSumSquares += sumSquares
        window.append((samples, sumSquares))
        windowSamples += samples
        windowSumSquares += sumSquares
        let pauseTarget = Int(SegmentCommitPlanner.pauseSeconds * Double(sampleRate))
        while let first = window.first, windowSamples - first.samples >= pauseTarget {
            windowSamples -= first.samples
            windowSumSquares -= first.sumSquares
            window.removeFirst()
        }

        let seconds = uncommittedSeconds
        var commit = seconds >= maximumSeconds
        if !commit, seconds >= minimumSeconds, segmentSamples > 0 {
            let segmentMean = segmentSumSquares / Double(segmentSamples)
            commit = trailingIsQuiet(seconds: SegmentCommitPlanner.pauseSeconds, fraction: SegmentCommitPlanner.pauseFraction, segmentMean: segmentMean)
            if !commit, seconds >= min(SegmentCommitPlanner.relaxedSeconds, maximumSeconds) {
                commit = trailingIsQuiet(seconds: SegmentCommitPlanner.gapSeconds, fraction: SegmentCommitPlanner.gapFraction, segmentMean: segmentMean)
            }
        }
        if commit { reset(); commits += 1 }
        return commit
    }

    /// Whether the last `seconds` of audio are quieter than `fraction` of the segment's average loudness.
    /// Energies are compared (squares), so the loudness fraction is squared too.
    private func trailingIsQuiet(seconds: Double, fraction: Double, segmentMean: Double) -> Bool {
        let target = Int(seconds * Double(sampleRate))
        var n = 0
        var sum = 0.0
        for item in window.reversed() {
            n += item.samples
            sum += item.sumSquares
            if n >= target { break }
        }
        guard n >= target, n > 0 else { return false }
        return sum / Double(n) <= segmentMean * fraction * fraction
    }

    private mutating func reset() {
        uncommittedBytes = 0
        segmentSamples = 0
        segmentSumSquares = 0
        window.removeAll()
        windowSamples = 0
        windowSumSquares = 0
    }

    static func energy(_ chunk: Data) -> (samples: Int, sumSquares: Double) {
        let count = chunk.count / 2
        guard count > 0 else { return (0, 0) }
        var sum = 0.0
        chunk.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        return (count, sum)
    }
}

/// Joins committed segments (and, while listening, the current partial) into one transcript.
public enum TranscriptSegments {
    public static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
