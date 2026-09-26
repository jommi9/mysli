import XCTest
@testable import MysliCore

final class EchoFilterTests: XCTestCase {
    /// Words spaced 0.3s apart starting at `at`, each lasting 0.25s.
    private func words(_ text: String, at: TimeInterval) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            let s = at + Double(i) * 0.3
            return TimedWord(text: String(w), start: s, end: s + 0.25)
        }
    }

    func testRemovesDelayedEchoOfSystemSpeech() {
        let system = words("we should ship the token launch in March.", at: 10)
        let mic = words("we should ship the token launch in March.", at: 10.12)
        let result = EchoFilter().removeEcho(mic: mic, system: system)
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.removed.count, mic.count)
    }

    func testKeepsOwnSpeechBetweenEchoes() {
        let system = words("so what do you think about the timeline", at: 0)
        let echo = words("so what do you think about the timeline", at: 0.1)
        let mine = words("I think March works for us", at: 6)
        let result = EchoFilter().removeEcho(mic: echo + mine, system: system)
        XCTAssertEqual(result.kept.map(\.text), mine.map(\.text))
    }

    func testKeepsRepetitionSpokenLater() {
        // Repeating their words back seconds later is you, not echo.
        let system = words("the audit finishes next week", at: 0)
        let mic = words("the audit finishes next week right", at: 4)
        let result = EchoFilter().removeEcho(mic: mic, system: system)
        XCTAssertEqual(result.kept.count, mic.count)
    }

    func testKeepsSingleCoincidentWord() {
        let system = words("yeah", at: 5)
        let mic = words("yeah", at: 5.2)
        let result = EchoFilter().removeEcho(mic: mic, system: system)
        XCTAssertEqual(result.kept.count, 1)
    }

    func testBridgesOneGarbledWord() {
        let system = words("the liquidity is really thin on weekends", at: 20)
        var mic = words("the liquidity is really thin on weekends", at: 20.1)
        mic[3].text = "rarely"
        let result = EchoFilter().removeEcho(mic: mic, system: system)
        XCTAssertTrue(result.kept.isEmpty)
    }

    func testRemovesShortWholeUtteranceEcho() {
        let system = words("sounds good", at: 30)
        let mic = words("sounds good", at: 30.1)
        let result = EchoFilter().removeEcho(mic: mic, system: system)
        XCTAssertTrue(result.kept.isEmpty)
    }

    func testNoSystemWordsKeepsEverything() {
        let mic = words("hello there", at: 0)
        XCTAssertEqual(EchoFilter().removeEcho(mic: mic, system: []).kept, mic)
    }

    func testLiveLineEcho() {
        let filter = EchoFilter()
        XCTAssertTrue(filter.isEcho(line: "We should ship in March", of: "we should ship in march."))
        XCTAssertFalse(filter.isEcho(line: "I disagree completely", of: "we should ship in march"))
        XCTAssertFalse(filter.isEcho(line: "yeah", of: "yeah"))
    }
}
