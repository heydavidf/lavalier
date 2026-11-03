import Foundation
import LavalierCore

// Synthetic test harness. Keys come from the environment (export ELEVENLABS_API_KEY and ANTHROPIC_API_KEY first); the app itself
// never reads the environment for keys. Nothing here records audio or prints keys.

func usage() -> Never {
    print("""
    lavalier-cli synthetic --files a.wav [b.wav ...] [--repeat N] [--no-cleanup] [--keyterms] [--no-pace] [--idle-seconds N] [--prewarm] [--no-speculation] [--parallel N] [--log out.jsonl] [--tally usage.json] [--dictionary file.txt]
    lavalier-cli cleanup --text "raw dictation text" [--model claude-sonnet-5-5]
    lavalier-cli usage
    lavalier-cli errors
    """)
    exit(2)
}

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted(); let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func values(_ name: String) -> [String] {
    guard let i = args.firstIndex(of: name) else { return [] }
    var out: [String] = []
    var j = i + 1
    while j < args.count, !args[j].hasPrefix("--") { out.append(args[j]); j += 1 }
    args.removeSubrange(i..<j)
    return out
}

// Test hooks: point at an unroutable host to exercise the offline/timeout paths without touching Wi-Fi.
if let host = ProcessInfo.processInfo.environment["LAVALIER_TEST_ELEVENLABS_WS"] { ElevenLabsRealtime.endpoint = URL(string: host)! }
if let host = ProcessInfo.processInfo.environment["LAVALIER_TEST_CLAUDE_URL"] { ClaudeClient.endpoint = URL(string: host)! }

let keys = EnvironmentKeyProvider()
let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

switch command {
case "synthetic":
    let files = values("--files")
    let repeatCount = Int(value("--repeat") ?? "1") ?? 1
    let noCleanup = flag("--no-cleanup")
    let keyterms = flag("--keyterms")
    let noPace = flag("--no-pace")
    let logPath = value("--log")
    let tallyPath = value("--tally")
    let dictionaryPath = value("--dictionary")
    // Latency experiment: --idle-seconds N waits before each run so connections go cold, as between
    // real dictations; --prewarm opens the Claude connection first, as the app does when the key goes down.
    let idleSeconds = Double(value("--idle-seconds") ?? "0") ?? 0
    let prewarm = flag("--prewarm")
    // --no-speculation and --parallel 1 restore the cleanup as it was before 3 November 2026.
    let noSpeculation = flag("--no-speculation")
    let parallel = Int(value("--parallel") ?? "") ?? PipelineConfig().parallelCleanupRequests
    guard !files.isEmpty else { usage() }
    var config = PipelineConfig()
    config.cleanupEnabled = !noCleanup
    config.sendKeyterms = keyterms
    config.speculativeCleanup = !noSpeculation
    config.parallelCleanupRequests = max(1, parallel)
    // Same dictionary source as the app (the text file), or an explicit file for tests.
    let dictionaryURL = dictionaryPath.map { URL(fileURLWithPath: $0) } ?? PersonalDictionary.fileURL()
    let terms = PersonalDictionary.load(from: dictionaryURL)
    print("dictionary (\(terms.count) terms from \(dictionaryURL.path)): \(terms.joined(separator: ", "))")
    let pipeline = DictationPipeline(keys: keys, dictionary: { terms }, config: config)
    var tally = tallyPath.map { UsageTally.load(from: URL(fileURLWithPath: $0)) }
    Task {
        var stt: [Double] = [], claude: [Double] = [], total: [Double] = [], audio = 0.0
        var failures = 0
        var logHandle: FileHandle?
        if let p = logPath {
            FileManager.default.createFile(atPath: p, contents: nil)
            logHandle = FileHandle(forWritingAtPath: p); logHandle?.seekToEndOfFile()
        }
        for round in 1...max(1, repeatCount) {
            for path in files {
                let name = (path as NSString).lastPathComponent
                do {
                    if idleSeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000)) }
                    if prewarm { await pipeline.prewarm() }
                    let wav = try WAVFile(contentsOf: URL(fileURLWithPath: path))
                    let pcm = wav.pcm16kMono()
                    let outcome = try await pipeline.run(audio: AudioChunking.stream(pcm, paced: !noPace))
                    stt.append(outcome.sttMs); total.append(outcome.totalMs); audio += outcome.audioSeconds
                    if let c = outcome.claudeMs { claude.append(c) }
                    if tally != nil {
                        tally!.record(usage: outcome.billedUsageEstimate, audioSeconds: outcome.audioSeconds, sttMs: outcome.sttMs,
                                      claudeMs: outcome.claudeMs, totalMs: outcome.totalMs)
                        try? tally!.save(to: URL(fileURLWithPath: tallyPath!))
                    }
                    let cleanupNote = outcome.cleanupSkippedReason.map { " (cleanup skipped: \($0))" }
                        ?? outcome.cleanupError.map { " (cleanup FAILED: \($0.userMessage))" } ?? ""
                    print(String(format: "[%d %@] audio %.1fs connect %.0fms stt %.0fms claude %@ total %.0fms%@",
                                 round, name, outcome.audioSeconds, outcome.connectMs, outcome.sttMs,
                                 outcome.claudeMs.map { String(format: "%.0fms", $0) } ?? "-", outcome.totalMs, cleanupNote)
                          + " [requests \(outcome.claudeRequests), speculation \(outcome.speculation ?? "-")]")
                    print("   raw:   \(outcome.raw)")
                    print("   final: \(outcome.finalText)")
                    if let spec = outcome.speculativeInput { print("   spec:  \(spec)") }
                    if let h = logHandle {
                        var rec: [String: Any] = ["round": round, "file": name, "audio_s": outcome.audioSeconds,
                                                  "connect_ms": outcome.connectMs.rounded(), "stt_ms": outcome.sttMs.rounded(),
                                                  "total_ms": outcome.totalMs.rounded(), "raw": outcome.raw, "final": outcome.finalText,
                                                  "partials": outcome.partialCount, "claude_requests": outcome.claudeRequests]
                        if let s = outcome.speculation { rec["speculation"] = s }
                        if let s = outcome.speculativeInput { rec["speculative_input"] = s }
                        if let c = outcome.claudeMs { rec["claude_ms"] = c.rounded() }
                        if let u = outcome.claudeUsage { rec["tokens_in"] = u.inputTokens; rec["tokens_out"] = u.outputTokens; rec["cache_read"] = u.cacheReadTokens }
                        if let s = outcome.cleanupSkippedReason { rec["cleanup_skipped"] = s }
                        if let e = outcome.cleanupError { rec["cleanup_error"] = e.userMessage }
                        h.write(try JSONSerialization.data(withJSONObject: rec) + Data("\n".utf8))
                    }
                } catch let e as DictationError {
                    failures += 1
                    print("[\(round) \(name)] FAILED: \(e.userMessage) [\(e)]")
                } catch {
                    failures += 1
                    print("[\(round) \(name)] FAILED: \(error)")
                }
            }
        }
        print(String(format: "\nruns %d  failures %d  audio sent %.1fs\nstt ms: median %.0f max %.0f\nclaude ms: median %.0f max %.0f (n=%d)\ntotal after release ms: median %.0f max %.0f",
                     total.count, failures, audio, median(stt), stt.max() ?? 0, median(claude), claude.max() ?? 0, claude.count,
                     median(total), total.max() ?? 0))
        if let t = tally {
            let m = t.month()
            print(String(format: "tally %@: %d calls, %d dictations, %d in / %d out tokens, about $%.4f, last total %.0f ms",
                         m.key, m.calls, m.dictations, m.inputTokens, m.outputTokens, m.estimatedDollars, t.last?.totalMs ?? 0))
        }
        exitCode = failures == 0 ? 0 : 1
        semaphore.signal()
    }

case "cleanup":
    let model = value("--model") ?? Cleanup.model
    guard let text = value("--text") else { usage() }
    Task {
        do {
            let client = ClaudeClient(apiKey: try keys.key(for: .anthropic), model: model)
            let r = try await client.cleanup(raw: text, systemPrompt: Cleanup.systemPrompt(dictionary: PersonalDictionary.seedTerms))
            print(String(format: "%@ %.0f ms, in %d out %d\n%@", r.model, r.milliseconds, r.usage.inputTokens, r.usage.outputTokens, r.text))
        } catch let e as DictationError { print("FAILED: \(e.userMessage)"); exitCode = 1 } catch { print("FAILED: \(error)"); exitCode = 1 }
        semaphore.signal()
    }

case "usage":
    Task {
        do {
            let s = try await ElevenLabsAccount.fetchSubscription(apiKey: try keys.key(for: .elevenLabs))
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            print("ElevenLabs \(s.tier) (\(s.status)): \(s.creditsUsed) of \(s.creditLimit) credits used, \(s.creditsRemaining) remaining, resets \(s.nextReset.map(f.string(from:)) ?? "?")")
        } catch let e as DictationError { print("FAILED: \(e.userMessage)"); exitCode = 1 } catch { print("FAILED: \(error)"); exitCode = 1 }
        semaphore.signal()
    }

case "errors":
    let samples: [DictationError] = [
        .missingKey(.elevenLabs), .missingKey(.anthropic), .offline, .connectTimeout, .transcriptTimeout, .cleanupTimeout,
        .elevenLabs(type: "quota_exceeded", message: ""), .elevenLabs(type: "rate_limited", message: ""),
        .elevenLabs(type: "session_time_limit_exceeded", message: ""), .elevenLabs(type: "insufficient_audio_activity", message: ""),
        .http(service: .elevenLabs, status: 401, message: ""), .http(service: .anthropic, status: 401, message: ""),
        .http(service: .anthropic, status: 429, message: ""), .http(service: .anthropic, status: 529, message: "overloaded"),
        .insertionFailed("Cmd-V could not be posted"), .permissionMissing("Accessibility"),
    ]
    for e in samples { print("\(e.isTransient ? "retry " : "final ") | \(e.userMessage)") }
    semaphore.signal()

default:
    usage()
}

semaphore.wait()
exit(exitCode)
