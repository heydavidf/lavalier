import XCTest
@testable import LavalierCore

/// Speculative cleanup start and parallel requests.
final class LatencyTests: XCTestCase {
    func testSameWordsIgnoresPunctuationAndCase() {
        XCTAssertTrue(CleanupSpeculation.sameWords("um so I think we should move it",
                                                   "Um, so I think we should move it."))
        XCTAssertTrue(CleanupSpeculation.sameWords("it's Friday", "It\u{2019}s Friday!"))
    }

    func testSameWordsRejectsMissingTail() {
        // Measured case: the live transcript at release lacked the last words of the dictation.
        XCTAssertFalse(CleanupSpeculation.sameWords(
            "Um, so I think we should, uh, move the meeting to Thursday. No, wait, I mean Friday afternoon.",
            "Um, so I think we should, uh, move the meeting to Thursday. No, wait, I mean Friday afternoon, and let Sarah know."))
    }

    func testSameWordsRejectsChangedWordAndEmpty() {
        XCTAssertFalse(CleanupSpeculation.sameWords("add an indexer", "add an index"))
        XCTAssertFalse(CleanupSpeculation.sameWords("", ""))
        XCTAssertFalse(CleanupSpeculation.sameWords("...", "..."))
    }

    func testFirstSuccessReturnsFastestCopy() async throws {
        let value = try await firstSuccess(count: 2) { i -> Int in
            try await Task.sleep(nanoseconds: i == 0 ? 300_000_000 : 10_000_000)
            return i
        }
        XCTAssertEqual(value, 1)
    }

    func testFirstSuccessSurvivesOneFailure() async throws {
        let value = try await firstSuccess(count: 2) { i -> Int in
            if i == 0 { throw DictationError.offline }
            try await Task.sleep(nanoseconds: 20_000_000)
            return 7
        }
        XCTAssertEqual(value, 7)
    }

    func testFirstSuccessThrowsWhenAllFail() async {
        do {
            _ = try await firstSuccess(count: 2) { _ -> Int in throw DictationError.cleanupTimeout }
            XCTFail("expected an error")
        } catch let e as DictationError {
            XCTAssertEqual(e, .cleanupTimeout)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testSingleCopyIsTheDefault() {
        XCTAssertEqual(PipelineConfig().parallelCleanupRequests, 1)
        XCTAssertTrue(PipelineConfig().speculativeCleanup)
    }

    func testBilledUsageCountsEveryRequest() {
        var outcome = DictationOutcome(raw: "a b c d", cleaned: "A b c d.", finalText: "A b c d.", audioSeconds: 2,
                                       connectMs: 200, sttMs: 250, claudeMs: 800,
                                       claudeUsage: ClaudeUsage(inputTokens: 300, outputTokens: 20),
                                       cleanupSkippedReason: nil, cleanupError: nil, partialCount: 2, totalMs: 1000)
        XCTAssertEqual(outcome.billedUsageEstimate, ClaudeUsage(inputTokens: 300, outputTokens: 20))
        outcome.claudeRequests = 2  // a discarded speculative start plus the real call
        XCTAssertEqual(outcome.billedUsageEstimate, ClaudeUsage(inputTokens: 600, outputTokens: 40))
    }
}
