import XCTest
@testable import MysliCore

final class VocabularyAlignmentTests: XCTestCase {
    private func w(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    func testMultiWordSpanCollapsesWithTiming() {
        let words = [w("we", 0, 0.2), w("bridged", 0.3, 0.6), w("to", 0.7, 0.8),
                     w("hyper", 0.9, 1.1), w("liquid.", 1.1, 1.5)]
        let out = VocabularyAlignment.apply(
            [.init(original: "hyper liquid.", replacement: "Hyperliquid")], to: words
        )
        XCTAssertEqual(out.map(\.text), ["we", "bridged", "to", "Hyperliquid."])
        XCTAssertEqual(out.last?.start, 0.9)
        XCTAssertEqual(out.last?.end, 1.5)
    }

    func testEachReplacementUsesNextUnconsumedSpan() {
        let words = [w("eigen", 0, 1), w("layer", 1, 2), w("and", 2, 3),
                     w("eigen", 3, 4), w("layer", 4, 5)]
        let r = VocabularyAlignment.Replacement(original: "eigen layer", replacement: "EigenLayer")
        let out = VocabularyAlignment.apply([r, r], to: words)
        XCTAssertEqual(out.map(\.text), ["EigenLayer", "and", "EigenLayer"])
    }

    func testUnmatchedReplacementIsIgnored() {
        let words = [w("hello", 0, 1)]
        let out = VocabularyAlignment.apply([.init(original: "nope", replacement: "Nope")], to: words)
        XCTAssertEqual(out, words)
    }

    func testWindowsBreakAtPausesOnWordStarts() {
        // Tokens every 1s; a 2s pause after token 99 (~100s in).
        var starts: [TimeInterval] = []
        var t: TimeInterval = 0
        for i in 0..<200 {
            if i == 100 { t += 2 }
            starts.append(t)
            t += 1
        }
        let ends = starts.map { $0 + 0.9 }
        let startsWord = [Bool](repeating: true, count: 200)
        let windows = VocabularyAlignment.windows(
            starts: starts, ends: ends, startsWord: startsWord, duration: t
        )
        // Every token in exactly one window, in order.
        XCTAssertEqual(windows.first?.tokens.lowerBound, 0)
        XCTAssertEqual(windows.last?.tokens.upperBound, 200)
        for (a, b) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(a.tokens.upperBound, b.tokens.lowerBound)
        }
        // No window exceeds the hard cap.
        for win in windows {
            XCTAssertLessThanOrEqual(ends[win.tokens.upperBound - 1] - starts[win.tokens.lowerBound], 151)
        }
        XCTAssertEqual(windows.first?.audioStart, 0)
    }

    func testWindowsNeverSplitAWord() {
        let starts = (0..<400).map { TimeInterval($0) * 0.5 }
        let ends = starts.map { $0 + 0.1 }
        // Only every 4th token starts a word.
        let startsWord = (0..<400).map { $0 % 4 == 0 }
        let windows = VocabularyAlignment.windows(
            starts: starts, ends: ends, startsWord: startsWord, duration: 200
        )
        XCTAssertGreaterThan(windows.count, 1)
        for win in windows.dropFirst() {
            XCTAssertTrue(startsWord[win.tokens.lowerBound])
        }
    }
}
