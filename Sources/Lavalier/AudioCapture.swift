import AVFoundation
import LavalierCore

/// Microphone to 16 kHz mono 16-bit PCM chunks. Nothing is written to disk.
///
/// Hotkey bug, 2 Nov 2026: with AirPods as the input, opening the microphone switches them to their call
/// mode, which changes the input device's format a moment after the engine started. AVAudioEngine then
/// stops by itself and the tap delivers nothing ("first buffer never, received 0.00 s, device changes 1"),
/// so every dictation ended as "No speech was heard". The engine is now restarted on the new format after
/// each configuration change, and a start that hits a device still switching ('!dev') is retried.
/// All methods run on the main thread.
final class AudioCapture {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var converter: AVAudioConverter?
    private(set) var isRunning = false
    private var configObserver: NSObjectProtocol?
    private var restartAttemptsLeft = AudioCapture.maximumRestarts

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    /// Small tap buffers so that stopping clips at most about 20 ms of the tail.
    static let tapBufferFrames: AVAudioFrameCount = 1024
    /// Attempts to start the microphone before giving up, and the pause between them.
    static let startAttempts = 3
    static let retryPause: TimeInterval = 0.25
    /// Restarts allowed after device changes during one dictation (guards against a restart loop).
    static let maximumRestarts = 8

    // Diagnostics: how much audio the microphone actually delivered.
    private var startedAt = Date()
    private var firstBufferAt: Date?
    private var lastBufferAt: Date?
    private var engineStartedAt = Date()
    private var watchdogRestarts = 0
    private var receivedSeconds: Double = 0
    private var inputRate: Double = 0
    private var outputBytes = 0
    private var configChanges = 0
    private var restarts = 0
    private var startFailures = 0

    /// One line for the log: wall time since start, delay to the first buffer, audio received and converted.
    var statsDescription: String {
        lock.lock(); defer { lock.unlock() }
        let wall = Date().timeIntervalSince(startedAt)
        let first = firstBufferAt.map { String(format: "%.0f ms", $0.timeIntervalSince(startedAt) * 1000) } ?? "never"
        let converted = Double(outputBytes) / 2 / AudioCapture.targetFormat.sampleRate
        return String(format: "open %.2f s, first buffer %@, received %.2f s (last format %.0f Hz), converted %.2f s, device changes %d, restarts %d (%d for silence), failed starts %d",
                      wall, first, receivedSeconds, inputRate, converted, configChanges, restarts, watchdogRestarts, startFailures)
    }

    /// Starts capture; the returned stream yields PCM chunks until `stop()` is called.
    func start() throws -> AsyncStream<Data> {
        let stream = AsyncStream<Data> { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
        lock.lock()
        startedAt = Date(); firstBufferAt = nil; receivedSeconds = 0; outputBytes = 0
        configChanges = 0; restarts = 0; startFailures = 0; lastBufferAt = nil; watchdogRestarts = 0
        lock.unlock()
        restartAttemptsLeft = AudioCapture.maximumRestarts
        var lastError: Error?
        for attempt in 1...AudioCapture.startAttempts {
            do {
                try startEngine()
                lastError = nil
                break
            } catch {
                lastError = error
                lock.lock(); startFailures += 1; lock.unlock()
                engine = AVAudioEngine()
                if attempt < AudioCapture.startAttempts { Thread.sleep(forTimeInterval: AudioCapture.retryPause) }
            }
        }
        if let lastError {
            removeObserver()
            lock.lock(); continuation = nil; converter = nil; lock.unlock()
            throw (lastError as? DictationError) ?? DictationError.audio(lastError.localizedDescription)
        }
        isRunning = true
        scheduleWatchdog()
        return stream
    }

    /// Stops the microphone and finishes the stream (this is the "key released" moment for the pipeline).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.converter = nil
        lock.unlock()
        continuation?.finish()
    }

    /// Installs the tap for the input's current format and starts the engine.
    private func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationError.audio("no input device")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: AudioCapture.targetFormat) else {
            throw DictationError.audio("cannot convert \(Int(inputFormat.sampleRate)) Hz input")
        }
        lock.lock()
        self.converter = converter
        inputRate = inputFormat.sampleRate
        lock.unlock()
        removeObserver()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
        let rate = inputFormat.sampleRate
        let ratio = AudioCapture.targetFormat.sampleRate / rate
        input.installTap(onBus: 0, bufferSize: AudioCapture.tapBufferFrames, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let continuation = self.continuation
            let converter = self.converter
            if continuation != nil {
                let now = Date()
                if self.firstBufferAt == nil { self.firstBufferAt = now }
                self.lastBufferAt = now
                self.receivedSeconds += Double(buffer.frameLength) / rate
            }
            self.lock.unlock()
            guard let continuation, let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: AudioCapture.targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
            self.lock.lock(); self.outputBytes += Int(out.frameLength) * 2; self.lock.unlock()
            continuation.yield(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError.audio(error.localizedDescription)
        }
        engineStartedAt = Date()
    }

    /// The input device or its format changed (AirPods entering call mode, a headset plugged in): the engine
    /// has stopped itself. Start it again on the new format while the key is still held.
    private func configurationChanged() {
        lock.lock(); configChanges += 1; lock.unlock()
        restartEngine()
    }

    private func restartEngine() {
        guard isRunning, restartAttemptsLeft > 0 else { return }
        restartAttemptsLeft -= 1
        // A fresh engine: the stopped one can restart "successfully" and still deliver nothing (measured).
        removeObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        do {
            try startEngine()
            lock.lock(); restarts += 1; lock.unlock()
        } catch {
            lock.lock(); startFailures += 1; lock.unlock()
            engine = AVAudioEngine()
            DispatchQueue.main.asyncAfter(deadline: .now() + AudioCapture.retryPause) { [weak self] in
                self?.restartEngine()
            }
        }
    }

    /// Silence from the engine (no buffer for this long after it started, or since the last buffer) means
    /// the device went away without a configuration-change notice: restart. Checked while the key is held.
    static let silentEngineSeconds: TimeInterval = 1.0

    private func scheduleWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isRunning else { return }
            self.lock.lock()
            let last = max(self.lastBufferAt ?? .distantPast, self.engineStartedAt)
            self.lock.unlock()
            if Date().timeIntervalSince(last) > AudioCapture.silentEngineSeconds, self.restartAttemptsLeft > 0 {
                self.lock.lock(); self.watchdogRestarts += 1; self.lock.unlock()
                self.restartEngine()
            }
            self.scheduleWatchdog()
        }
    }

    private func removeObserver() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
    }
}
