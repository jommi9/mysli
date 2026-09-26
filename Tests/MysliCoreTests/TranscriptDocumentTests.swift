import XCTest
@testable import MysliCore

final class TranscriptDocumentTests: XCTestCase {
    private func words(_ text: String, at: TimeInterval) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { i, w in
            let s = at + Double(i) * 0.3
            return TimedWord(text: String(w), start: s, end: s + 0.25)
        }
    }

    private func sample() -> TranscriptDocument {
        TranscriptDocument.build(
            session: .init(
                id: "2026.09.26-1400",
                title: "Meeting 2026-09-26 14:00",
                started_at: "2026-09-26T14:00:00+02:00",
                ended_at: "2026-09-26T14:30:00+02:00",
                duration_seconds: 1800,
                timezone: "Europe/Berlin"
            ),
            engine: .init(name: "parakeet", model: "v2", vocabulary: false, echo_filter: true, echo_words_removed: 3),
            createdAt: "2026-09-26T14:31:00+02:00",
            words: [
                "them": words("How is the launch going?", at: 1) + words("Great.", at: 9),
                "me": words("Mostly on track. Audit is done.", at: 4),
            ]
        )
    }

    func testSegmentsAreMergedByTimeWithIds() {
        let doc = sample()
        XCTAssertEqual(doc.schema, "mysli.transcript/2")
        XCTAssertEqual(doc.segments.map(\.speaker), ["them", "me", "me", "them"])
        XCTAssertEqual(doc.segments.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(doc.segments[1].text, "Mostly on track.")
        XCTAssertEqual(doc.segments[1].words.count, 3)
        XCTAssertEqual(doc.segments[0].start_ms, 1000)
    }

    func testSpeakerStats() {
        let doc = sample()
        XCTAssertEqual(doc.speakers.map(\.id), ["me", "them"])
        let me = doc.speakers[0]
        XCTAssertEqual(me.source, "microphone")
        XCTAssertEqual(me.word_count, 6)
        XCTAssertEqual(me.segment_count, 2)
        XCTAssertEqual(doc.speakers.reduce(0) { $0 + $1.talk_share }, 1, accuracy: 0.002)
    }

    func testJSONRoundTrip() throws {
        let doc = sample()
        let decoded = try TranscriptDocument.decode(from: doc.jsonData())
        XCTAssertEqual(decoded, doc)
    }

    func testMarkdownHasFrontMatterAndLines() {
        let md = sample().markdown()
        XCTAssertTrue(md.hasPrefix("---\ntitle: \"Meeting 2026-09-26 14:00\"\n"))
        XCTAssertTrue(md.contains("date: 2026-09-26T14:00:00+02:00"))
        XCTAssertTrue(md.contains("  - id: me\n    source: microphone"))
        XCTAssertTrue(md.contains("**[0:01] Them:** How is the launch going?"))
        XCTAssertTrue(md.contains("_30 min · Me "))
    }

    func testTurnsMergeConsecutiveSegmentsOfOneSpeaker() {
        let turns = sample().turns()
        XCTAssertEqual(turns.map(\.speaker), ["them", "me", "them"])
        XCTAssertEqual(turns[1].text, "Mostly on track. Audit is done.")
        XCTAssertEqual(turns[1].segmentIDs, [1, 2])
        // A long pause splits a turn even without a speaker change.
        XCTAssertEqual(sample().turns(maxGapMs: 0).count, 4)
    }

    func testClock() {
        XCTAssertEqual(TranscriptDocument.clock(65_000), "1:05")
        XCTAssertEqual(TranscriptDocument.clock(3_725_000), "1:02:05")
    }
}

final class NotionPayloadTests: XCTestCase {
    func testLongTextIsSplitUnderLimit() {
        let text = Array(repeating: "liquidity", count: 600).joined(separator: " ")
        let items = NotionPayload.richText(text)
        XCTAssertGreaterThan(items.count, 1)
        let contents = items.compactMap { $0["text"]?["content"]?.stringValue }
        XCTAssertTrue(contents.allSatisfy { $0.utf16.count <= NotionPayload.maxTextLength })
        XCTAssertEqual(contents.joined(separator: " "), text)
    }

    func testHugeSingleWordIsCut() {
        let word = String(repeating: "x", count: 4500)
        let chunks = NotionPayload.chunks(word, limit: 2000)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 2000 })
        XCTAssertEqual(chunks.joined(), word)
    }

    func testBatches() {
        let batches = NotionPayload.batches(Array(0..<250))
        XCTAssertEqual(batches.map(\.count), [100, 100, 50])
    }

    func testBlocksAndProperties() {
        let doc = TranscriptDocument.build(
            session: .init(id: "s", title: "T", started_at: "2026-09-26T14:00:00+02:00",
                           ended_at: nil, duration_seconds: 60, timezone: "UTC"),
            engine: .init(name: "p", model: "m", vocabulary: false, echo_filter: true, echo_words_removed: 0),
            createdAt: "x",
            words: ["me": [TimedWord(text: "Hello.", start: 0, end: 0.5)]]
        )
        let blocks = NotionPayload.blocks(for: doc)
        // summary, divider, one segment
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1]["type"], .string("divider"))
        let rich = blocks[2]["paragraph"]?["rich_text"]
        guard case .array(let items)? = rich else { return XCTFail("no rich text") }
        XCTAssertEqual(items.compactMap { $0["text"]?["content"]?.stringValue }, ["0:00  ", "Me: ", "Hello."])

        let props = NotionPayload.properties(document: doc, titleProperty: "Name", dateProperty: "When")
        XCTAssertEqual(props["When"]?["date"]?["start"], .string("2026-09-26T14:00:00+02:00"))
        XCTAssertNotNil(props["Name"]?["title"])
    }
}
