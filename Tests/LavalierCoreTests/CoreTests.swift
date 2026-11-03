import CoreGraphics
import XCTest
import AppKit
@testable import LavalierCore

final class HotkeyTests: XCTestCase {
    func testRightOptionPressAndRelease() {
        var t = HotkeyTracker(choice: .rightOption)
        // Right option down: keycode 61 with the right-alt device bit set (plus the generic alternate flag).
        XCTAssertEqual(t.handle(keyCode: 61, flagsRaw: CGEventFlags.maskAlternate.rawValue | 0x40), .pressed)
        XCTAssertNil(t.handle(keyCode: 61, flagsRaw: CGEventFlags.maskAlternate.rawValue | 0x40), "repeat down is ignored")
        XCTAssertEqual(t.handle(keyCode: 61, flagsRaw: 0), .released)
        XCTAssertNil(t.handle(keyCode: 61, flagsRaw: 0), "repeat up is ignored")
    }

    func testLeftOptionDoesNotTriggerRightOption() {
        var t = HotkeyTracker(choice: .rightOption)
        XCTAssertNil(t.handle(keyCode: 58, flagsRaw: CGEventFlags.maskAlternate.rawValue | 0x20))
    }

    func testOtherKeysIgnoredAndFnUsesSecondaryFnFlag() {
        var t = HotkeyTracker(choice: .fn)
        XCTAssertNil(t.handle(keyCode: 61, flagsRaw: 0x40))
        XCTAssertEqual(t.handle(keyCode: 63, flagsRaw: CGEventFlags.maskSecondaryFn.rawValue), .pressed)
        XCTAssertEqual(t.handle(keyCode: 63, flagsRaw: 0), .released)
    }

    func testTrackerResetReportsNothingButClearsDown() {
        var t = HotkeyTracker(choice: .rightCommand)
        XCTAssertEqual(t.handle(keyCode: 54, flagsRaw: 0x10 | CGEventFlags.maskCommand.rawValue), .pressed)
        XCTAssertTrue(t.isDown)
        t.reset()
        XCTAssertFalse(t.isDown)
        XCTAssertEqual(t.handle(keyCode: 54, flagsRaw: 0x10), .pressed, "a fresh press after reset is seen")
    }

    func testEveryChoiceHasDistinctKeyCodeAndLabel() {
        let codes = Set(HotkeyChoice.allCases.map(\.keyCode))
        XCTAssertEqual(codes.count, HotkeyChoice.allCases.count)
        XCTAssertNotNil(HotkeyChoice.fn.note)
        // MacBook keyboards have no Right Control key, so Settings must say so (hotkey bug, 2 Nov 2026).
        XCTAssertTrue(HotkeyChoice.rightControl.note?.contains("no Right Control") ?? false)
    }
}

final class DictionaryTests: XCTestCase {
    func testParseTrimsDedupesAndSkipsComments() {
        let terms = PersonalDictionary.parse("  Lavalier \n\n# comment\nlavalier\nElevenLabs\r\nClaude\n")
        XCTAssertEqual(terms, ["Lavalier", "ElevenLabs", "Claude"])
    }

    func testRoundTripThroughFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString).txt")
        try PersonalDictionary.save(["Alpha", "Beta"], to: url)
        XCTAssertEqual(PersonalDictionary.load(from: url), ["Alpha", "Beta"])
        XCTAssertEqual(PersonalDictionary.load(from: url.appendingPathExtension("missing")), PersonalDictionary.seedTerms)
    }

    func testPromptContainsTermsAndRules() {
        let p = Cleanup.systemPrompt(dictionary: ["Lavalier", "ElevenLabs"])
        XCTAssertTrue(p.contains("Lavalier, ElevenLabs"))
        XCTAssertTrue(p.contains("British spelling"))
        XCTAssertFalse(Cleanup.systemPrompt(dictionary: []).contains("Use these spellings"))
    }

    func testShortDictationsSkipCleanup() {
        XCTAssertFalse(Cleanup.shouldClean("send it now"))
        XCTAssertTrue(Cleanup.shouldClean("please send it now"))
    }
}

final class KeychainTests: XCTestCase {
    let store = KeychainStore(service: "Lavalier.tests")

    override func tearDownWithError() throws {
        try store.delete(account: "unit")
    }

    func testSetGetUpdateDelete() throws {
        try store.delete(account: "unit")
        XCTAssertNil(try store.get(account: "unit"))
        XCTAssertFalse(store.has(account: "unit"))
        try store.set("first-value", account: "unit")
        XCTAssertEqual(try store.get(account: "unit"), "first-value")
        try store.set("second-value", account: "unit")
        XCTAssertEqual(try store.get(account: "unit"), "second-value")
        XCTAssertTrue(store.has(account: "unit"))
        try store.delete(account: "unit")
        XCTAssertNil(try store.get(account: "unit"))
    }

    func testProvidersThrowMissingKey() {
        let provider = KeychainKeyProvider(store: KeychainStore(service: "Lavalier.tests.empty"))
        XCTAssertThrowsError(try provider.key(for: .elevenLabs)) { error in
            XCTAssertEqual(error as? DictationError, .missingKey(.elevenLabs))
        }
    }
}

final class PasteboardTests: XCTestCase {
    func testSnapshotRestoresTextRichTextAndImage() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("dictation-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rtf = try NSAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            .data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        pb.clearContents()
        let textItem = NSPasteboardItem()
        textItem.setString("original text", forType: .string)
        textItem.setData(rtf, forType: .rtf)
        let imageItem = NSPasteboardItem()
        imageItem.setData(tiff, forType: .tiff)
        XCTAssertTrue(pb.writeObjects([textItem, imageItem]))

        let snapshot = PasteboardSnapshot(pasteboard: pb)
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertTrue(snapshot.unreadableTypes.isEmpty)

        let change = PasteboardSnapshot.writeTransient(text: "dictated words", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "dictated words")
        XCTAssertNotNil(pb.pasteboardItems?.first?.data(forType: PasteboardSnapshot.transientType))
        XCTAssertEqual(change, pb.changeCount)
        XCTAssertEqual(Array(snapshot.items[0].types.map(\.type).prefix(2)), [.string, .rtf], "type order is preserved (macOS appends a utf16 variant)")

        XCTAssertTrue(snapshot.restore(to: pb))
        let items = try XCTUnwrap(pb.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "original text")
        XCTAssertEqual(items[0].data(forType: .rtf), rtf)
        XCTAssertEqual(items[1].data(forType: .tiff), tiff)
        XCTAssertNil(items[0].data(forType: PasteboardSnapshot.transientType))
        XCTAssertEqual(Array(items[0].types.prefix(2)), [.string, .rtf], "restored items keep the original type order")
    }

    func testEmptySnapshotRestoresToEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name("dictation-tests-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot(pasteboard: pb)
        XCTAssertTrue(snapshot.isEmpty)
        _ = PasteboardSnapshot.writeTransient(text: "x", to: pb)
        snapshot.restore(to: pb)
        XCTAssertNil(pb.string(forType: .string))
    }

    func testKeychainPresenceDoesNotNeedTheValue() throws {
        let store = KeychainStore(service: "Lavalier.tests.presence")
        try store.set("v", account: "a")
        XCTAssertTrue(store.has(account: "a"))
        try store.delete(account: "a")
        XCTAssertFalse(store.has(account: "a"))
    }
}

final class UsageTests: XCTestCase {
    func testTallyAccumulatesAndPersists() throws {
        var tally = UsageTally()
        let at = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26
        tally.record(usage: ClaudeUsage(inputTokens: 350, outputTokens: 60), audioSeconds: 7.7, sttMs: 240, claudeMs: 1200, totalMs: 1450, at: at)
        tally.record(usage: nil, audioSeconds: 1.8, sttMs: 250, claudeMs: nil, totalMs: 255, at: at)
        let m = tally.month(UsageTally.monthKey(for: at))
        XCTAssertEqual(m.calls, 1)
        XCTAssertEqual(m.dictations, 2)
        XCTAssertEqual(m.inputTokens, 350)
        XCTAssertEqual(m.outputTokens, 60)
        XCTAssertEqual(m.estimatedDollars, 350 * 0.10 / 1e6 + 60 * 0.50 / 1e6, accuracy: 1e-12)
        XCTAssertEqual(tally.last?.totalMs, 255)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString).json")
        try tally.save(to: url)
        XCTAssertEqual(UsageTally.load(from: url), tally)
        XCTAssertEqual(UsageTally.load(from: url.appendingPathExtension("missing")), UsageTally())
    }

    func testHaikuPricing() {
        let u = ClaudeUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        XCTAssertEqual(u.estimatedDollars, 0.60, accuracy: 1e-9)
    }
}

final class ErrorTests: XCTestCase {
    func testEveryErrorHasPlainLanguageText() {
        let all: [DictationError] = [
            .missingKey(.anthropic), .offline, .connectTimeout, .transcriptTimeout, .cleanupTimeout,
            .elevenLabs(type: "quota_exceeded", message: ""), .elevenLabs(type: "weird_new_type", message: "detail"),
            .http(service: .anthropic, status: 401, message: ""), .http(service: .elevenLabs, status: 503, message: ""),
            .network("lost"), .badResponse(.elevenLabs, "x"), .insertionFailed("y"), .permissionMissing("Accessibility"), .audio("z"),
        ]
        for e in all { XCTAssertFalse(e.userMessage.isEmpty, "\(e)") }
        XCTAssertTrue(DictationError.elevenLabs(type: "weird_new_type", message: "detail").userMessage.contains("detail"))
    }

    func testTransientClassification() {
        XCTAssertTrue(DictationError.http(service: .anthropic, status: 529, message: "").isTransient)
        XCTAssertTrue(DictationError.elevenLabs(type: "rate_limited", message: "").isTransient)
        XCTAssertFalse(DictationError.elevenLabs(type: "quota_exceeded", message: "").isTransient)
        XCTAssertFalse(DictationError.http(service: .anthropic, status: 401, message: "").isTransient)
        XCTAssertFalse(DictationError.missingKey(.elevenLabs).isTransient)
        // commit_throttled means "less than 0.3 s of audio": replaying the same recording cannot succeed,
        // and it is not a rate limit, whatever its name says (hotkey bug, 2 Nov 2026).
        let tooShort = DictationError.elevenLabs(type: "commit_throttled", message: "only 0.04s of uncommitted audio")
        XCTAssertFalse(tooShort.isTransient)
        XCTAssertFalse(tooShort.userMessage.contains("busy"))
        XCTAssertTrue(tooShort.userMessage.contains("too short"))
    }

    /// A key tap, or a Bluetooth microphone that takes most of the hold to start, gives under 0.3 s of audio;
    /// ElevenLabs then ignores the commit. The final chunk is padded so every commit meets the minimum.
    func testFinalChunkMeetsTheCommitMinimum() {
        let minimum = Int(ElevenLabsRealtime.minimumCommitSeconds * Double(ElevenLabsRealtime.sampleRate)) * 2
        // Nothing captured at all (the old fallback sent 0.1 s, which ElevenLabs also rejects).
        XCTAssertGreaterThanOrEqual(ElevenLabsRealtime.finalChunk(nil, alreadySent: 0).count, minimum)
        // 40 ms captured, as in the reproduction: padded with silence after the real audio.
        let speech = Data(repeating: 7, count: 1280)
        let padded = ElevenLabsRealtime.finalChunk(speech, alreadySent: 0)
        XCTAssertGreaterThanOrEqual(padded.count, minimum)
        XCTAssertEqual(padded.prefix(1280), speech, "real audio comes first, unchanged")
        XCTAssertTrue(padded.dropFirst(1280).allSatisfy { $0 == 0 }, "padding is silence")
        // Earlier chunks count towards the minimum.
        XCTAssertGreaterThanOrEqual(ElevenLabsRealtime.finalChunk(speech, alreadySent: 8000).count + 8000, minimum)
        // A normal dictation is sent unchanged.
        let long = Data(repeating: 3, count: 4096)
        XCTAssertEqual(ElevenLabsRealtime.finalChunk(long, alreadySent: 32000), long)
    }

    func testWithTimeoutFires() async {
        do {
            _ = try await withTimeout(seconds: 0.05, error: .connectTimeout) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 2_000_000_000); return 1
            }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? DictationError, .connectTimeout)
        }
    }
}

final class AudioTests: XCTestCase {
    private func makeWav(sampleRate: Int, channels: Int, frames: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(frames * channels * 2)
        d.append(contentsOf: "RIFF".utf8); u32(36 + dataSize); d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        d.append(contentsOf: "data".utf8); u32(dataSize)
        for i in 0..<(frames * channels) { u16(UInt16(bitPattern: Int16(truncatingIfNeeded: i))) }
        return d
    }

    func testParsesWavAndChunks() throws {
        let wav = try WAVFile(data: makeWav(sampleRate: 16000, channels: 1, frames: 16000))
        XCTAssertEqual(wav.sampleRate, 16000)
        XCTAssertEqual(wav.seconds, 1.0, accuracy: 1e-9)
        let pcm = wav.pcm16kMono()
        XCTAssertEqual(pcm.count, 32000)
        let chunks = AudioChunking.chunks(pcm)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.last?.count, 32000 - 3 * 8192)
    }

    func testDownmixesStereo48k() throws {
        let wav = try WAVFile(data: makeWav(sampleRate: 48000, channels: 2, frames: 4800))
        XCTAssertEqual(wav.pcm16kMono().count, 1600 * 2)
    }

    func testRejectsNonWav() {
        XCTAssertThrowsError(try WAVFile(data: Data("not audio at all, really".utf8)))
    }

    func testStreamDeliversAllBytes() async {
        let pcm = Data(count: 20000)
        var total = 0
        for await c in AudioChunking.stream(pcm, paced: false) { total += c.count }
        XCTAssertEqual(total, 20000)
    }
}

final class OnboardingPolicyTests: XCTestCase {
    func testLaunchWithMissingPermissionAlwaysShowsAndClearsFlag() {
        // The bug: the flag had been set by an earlier run, so the window never appeared again.
        XCTAssertEqual(OnboardingPolicy.atLaunch(missingRequired: true, dismissed: true), .init(showWindow: true, dismissed: false))
        XCTAssertEqual(OnboardingPolicy.atLaunch(missingRequired: true, dismissed: false), .init(showWindow: true, dismissed: false))
    }

    func testLaunchWithEverythingGrantedKeepsFlagAndHidesWindow() {
        XCTAssertEqual(OnboardingPolicy.atLaunch(missingRequired: false, dismissed: true), .init(showWindow: false, dismissed: true))
        XCTAssertEqual(OnboardingPolicy.atLaunch(missingRequired: false, dismissed: false), .init(showWindow: false, dismissed: false))
    }

    func testOnlyClosingSetsTheFlag() {
        XCTAssertFalse(OnboardingPolicy.afterRefresh(dismissed: false), "a two-second refresh must not dismiss")
        XCTAssertTrue(OnboardingPolicy.afterRefresh(dismissed: true))
        XCTAssertTrue(OnboardingPolicy.afterClose())
        XCTAssertTrue(OnboardingPolicy.whenPermissionMissing(dismissed: false))
        XCTAssertFalse(OnboardingPolicy.whenPermissionMissing(dismissed: true), "no nagging after the user closed it")
    }
}

final class InsertionPolicyTests: XCTestCase {
    func testBrowsersAndElectronAppsArePasteOnly() {
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
                   "com.tinyspeck.slackmacgap", "md.obsidian", "com.anthropic.claudefordesktop"] {
            XCTAssertNotNil(InsertionPolicy.pasteOnlyReason(bundleID: id, ancestorRoles: []), id)
        }
    }

    func testWebContentAncestorIsPasteOnlyInAnyApp() {
        let reason = InsertionPolicy.pasteOnlyReason(bundleID: "com.example.native", ancestorRoles: ["AXGroup", "AXWebArea"])
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("AXWebArea"))
    }

    func testNativeAppsMayUseAccessibility() {
        XCTAssertNil(InsertionPolicy.pasteOnlyReason(bundleID: "com.apple.Notes", ancestorRoles: ["AXScrollArea", "AXWindow"]))
        XCTAssertNil(InsertionPolicy.pasteOnlyReason(bundleID: "com.apple.mail", ancestorRoles: []))
        XCTAssertNil(InsertionPolicy.pasteOnlyReason(bundleID: nil, ancestorRoles: []))
    }
}

final class HotkeyDefaultTests: XCTestCase {
    private func freshSettings() -> (AppSettings, () -> Void) {
        let suite = "LavalierTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    func testDefaultAvoidsTheKeysOtherToolsUse() {
        XCTAssertEqual(HotkeyChoice.default, .rightControl)
        XCTAssertFalse(HotkeyChoice.conflicting.contains(HotkeyChoice.default))
        XCTAssertEqual(HotkeyChoice.conflicting, [.rightOption, .rightCommand])
        XCTAssertNotNil(HotkeyChoice.rightOption.note)
        XCTAssertNotNil(HotkeyChoice.rightCommand.note)
        XCTAssertEqual(HotkeyChoice.allCases.first, .rightControl, "the safe key is listed first in Settings")
    }

    func testMigrationMovesOffAConflictingKeyExactlyOnce() {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        settings.hotkey = .rightCommand
        XCTAssertEqual(settings.migrateHotkeyAwayFromConflicts(), .rightCommand)
        XCTAssertEqual(settings.hotkey, .rightControl)
        settings.hotkey = .rightCommand // chosen again on purpose
        XCTAssertNil(settings.migrateHotkeyAwayFromConflicts())
        XCTAssertEqual(settings.hotkey, .rightCommand, "a deliberate later choice is respected")
    }

    func testMigrationLeavesASafeKeyAlone() {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        settings.hotkey = .fn
        XCTAssertNil(settings.migrateHotkeyAwayFromConflicts())
        XCTAssertEqual(settings.hotkey, .fn)
    }

    func testNewPreferencesDefaultOn() {
        let (settings, cleanup) = freshSettings()
        defer { cleanup() }
        XCTAssertTrue(settings.soundCuesEnabled)
        XCTAssertTrue(settings.indicatorEnabled)
        XCTAssertEqual(settings.menuBarGlyph, .lavalier)
        XCTAssertFalse(settings.onboardingDismissed)
    }
}

final class MenuBarGlyphTests: XCTestCase {
    func testEveryStyleAndStateRenders() {
        for style in MenuBarGlyphStyle.allCases {
            for state in MenuBarGlyphState.allCases {
                let image = MenuBarGlyph.image(style: style, state: state)
                XCTAssertEqual(image.size, MenuBarGlyph.size)
                XCTAssertTrue(image.isTemplate)
                let png = MenuBarGlyph.png(style: style, state: state)
                XCTAssertNotNil(png, "\(style) \(state)")
                XCTAssertGreaterThan(png?.count ?? 0, 200, "\(style) \(state) drew nothing")
            }
        }
    }

    func testStylesAndStatesLookDifferent() {
        let a = MenuBarGlyph.png(style: .lavalier, state: .idle)
        let b = MenuBarGlyph.png(style: .pillWave, state: .idle)
        let c = MenuBarGlyph.png(style: .lavalier, state: .listening)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

/// Hotkey bug, 2 Nov 2026: Settings said Right Control while the user held Right Command and nothing happened.
final class WrongKeyDetectorTests: XCTestCase {
    let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
    let ctrl = UInt64(CGEventFlags.maskControl.rawValue)

    func testHoldingAnotherPushToTalkKeyAloneIsReported() {
        var d = WrongKeyDetector(chosen: .rightControl)
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: cmd | 0x10, at: 10.0))
        XCTAssertEqual(d.handle(keyCode: 54, flagsRaw: 0, at: 11.5), .rightCommand)
    }

    func testShortTapsTheChosenKeyAndCombinationsAreIgnored() {
        var d = WrongKeyDetector(chosen: .rightControl)
        // A quick tap is not an attempt to dictate.
        _ = d.handle(keyCode: 54, flagsRaw: cmd | 0x10, at: 0)
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: 0, at: 0.3))
        // The chosen key itself is never reported.
        _ = d.handle(keyCode: 62, flagsRaw: ctrl | 0x2000, at: 1)
        XCTAssertNil(d.handle(keyCode: 62, flagsRaw: 0, at: 3))
        // Held together with another modifier (a shortcut), not reported.
        _ = d.handle(keyCode: 54, flagsRaw: cmd | 0x10 | UInt64(CGEventFlags.maskShift.rawValue), at: 4)
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: 0, at: 6))
        // Another modifier pressed during the hold cancels it.
        _ = d.handle(keyCode: 54, flagsRaw: cmd | 0x10, at: 7)
        _ = d.handle(keyCode: 56, flagsRaw: cmd | 0x10 | 0x2, at: 7.2)
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: 0, at: 9))
        // Left Command (key code 55) is not a push-to-talk choice.
        _ = d.handle(keyCode: 55, flagsRaw: cmd | 0x8, at: 10)
        XCTAssertNil(d.handle(keyCode: 55, flagsRaw: 0, at: 12))
    }

    func testChangingTheChosenKeyStopsReportingIt() {
        var d = WrongKeyDetector(chosen: .rightControl)
        d.update(chosen: .rightCommand)
        _ = d.handle(keyCode: 54, flagsRaw: cmd | 0x10, at: 0)
        XCTAssertNil(d.handle(keyCode: 54, flagsRaw: 0, at: 2))
    }
}
