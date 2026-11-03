import Foundation

/// Time limits for one dictation. The held key used to be released automatically after 120 s
/// and the WebSocket's resource timeout was also 120 s, so nothing longer than two minutes could be captured.
public enum DictationLimits {
    /// A held key is released automatically after this long, so the microphone can never stay open.
    public static let maximumHoldSeconds: Double = 600
    /// After release, the pipeline and insertion must finish within this time or the dictation is abandoned.
    /// Long dictations need longer: the last segment's transcript, then a cleanup whose length grows with the text.
    public static let baseProcessingSeconds: Double = 25
    public static let processingSecondsPerHeldSecond: Double = 0.05

    public static func processingDeadline(heldSeconds: Double) -> Double {
        baseProcessingSeconds + max(0, heldSeconds) * processingSecondsPerHeldSecond
    }
}
