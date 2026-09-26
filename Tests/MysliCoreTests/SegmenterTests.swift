import XCTest
@testable import MysliCore

final class SegmenterTests: XCTestCase {
    func testBreaksOnSentenceEndAndGap() {
        let words = [
            TimedWord(text: "Hi.", start: 0, end: 0.3),
            TimedWord(text: "How", start: 0.5, end: 0.7),
            TimedWord(text: "are", start: 0.8, end: 0.9),
            TimedWord(text: "you", start: 3.0, end: 3.2),
        ]
        let segments = Segmenter.segments(from: words)
        XCTAssertEqual(segments.map(\.text), ["Hi.", "How are", "you"])
        XCTAssertEqual(segments[1].start, 0.5)
        XCTAssertEqual(segments[1].end, 0.9)
    }

    func testNormalizer() {
        XCTAssertEqual(WordNormalizer.normalize("Yeah,"), "yeah")
        XCTAssertEqual(WordNormalizer.normalize("Hääyö!"), "hääyö")
        XCTAssertEqual(WordNormalizer.normalize("—"), "")
        XCTAssertEqual(WordNormalizer.words(in: "It's 10x, ok?"), ["its", "10x", "ok"])
    }
}
