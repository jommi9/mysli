import XCTest
@testable import MysliCore

final class MeetingInfoTests: XCTestCase {
    private let me = MeetingInfo.Attendee(name: "Joakim", email: "j@x.com", is_self: true)

    private func meeting(_ attendees: [MeetingInfo.Attendee], title: String = "Weekly sync") -> MeetingInfo {
        MeetingInfo(title: title, starts_at: "2026-09-26T10:30:00+02:00", ends_at: "2026-09-26T11:00:00+02:00",
                    organizer: "Anna", attendees: attendees)
    }

    func testOtherPersonInOneOnOne() {
        let anna = MeetingInfo.Attendee(name: "Anna Korhonen", email: "anna@x.com", is_self: false)
        XCTAssertEqual(meeting([me, anna]).otherPersonName, "Anna Korhonen")
        // No name, or the name is just the email: use the email's local part.
        let bare = MeetingInfo.Attendee(name: "anna.k@x.com", email: "anna.k@x.com", is_self: false)
        XCTAssertEqual(meeting([me, bare]).otherPersonName, "anna.k")
        // Group meetings keep "Them".
        let ben = MeetingInfo.Attendee(name: "Ben", email: nil, is_self: false)
        XCTAssertNil(meeting([me, anna, ben]).otherPersonName)
        XCTAssertNil(meeting([]).otherPersonName)
    }

    func testBestMatchPrefersEventsWithGuestsAndNearestStart() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let candidates = [
            MeetingMatcher.Candidate(start: t.addingTimeInterval(-3600), end: t.addingTimeInterval(3600),
                                     isAllDay: false, attendeeCount: 0),          // focus block
            MeetingMatcher.Candidate(start: t.addingTimeInterval(300), end: t.addingTimeInterval(2100),
                                     isAllDay: false, attendeeCount: 2),          // call starting in 5 min
            MeetingMatcher.Candidate(start: t.addingTimeInterval(-86400), end: t.addingTimeInterval(86400),
                                     isAllDay: true, attendeeCount: 5),           // all-day
        ]
        XCTAssertEqual(MeetingMatcher.bestMatch(for: t, in: candidates), 1)
    }

    func testBestMatchWindow() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let starting = MeetingMatcher.Candidate(start: t.addingTimeInterval(20 * 60), end: t.addingTimeInterval(50 * 60),
                                                isAllDay: false, attendeeCount: 1)
        XCTAssertNil(MeetingMatcher.bestMatch(for: t, in: [starting]), "starts too far ahead")
        let over = MeetingMatcher.Candidate(start: t.addingTimeInterval(-3600), end: t,
                                            isAllDay: false, attendeeCount: 1)
        XCTAssertNil(MeetingMatcher.bestMatch(for: t, in: [over]), "already ended")
        let late = MeetingMatcher.Candidate(start: t.addingTimeInterval(-15 * 60), end: t.addingTimeInterval(15 * 60),
                                            isAllDay: false, attendeeCount: 1)
        XCTAssertEqual(MeetingMatcher.bestMatch(for: t, in: [late]), 0, "joined late")
    }

    func testFileSafe() {
        XCTAssertEqual(MeetingMatcher.fileSafe("Anna / Joakim: 1:1  \n sync?"), "Anna Joakim 1 1 sync")
        XCTAssertEqual(MeetingMatcher.fileSafe(String(repeating: "a", count: 100)).count, 60)
    }

    func testDocumentUsesCalendar() throws {
        let anna = MeetingInfo.Attendee(name: "Anna", email: "anna@x.com", is_self: false)
        let doc = TranscriptDocument.build(
            session: .init(id: "2026.09.26-1030", title: "Weekly sync", started_at: nil, ended_at: nil,
                           duration_seconds: 600, timezone: "UTC", calendar: meeting([me, anna])),
            engine: .init(name: "p", model: "m", vocabulary: false, echo_filter: true, echo_words_removed: 0),
            createdAt: "x",
            words: [
                "them": [TimedWord(text: "Hi.", start: 0, end: 0.3)],
                "me": [TimedWord(text: "Hey.", start: 1, end: 1.3)],
            ]
        )
        XCTAssertEqual(doc.label(for: "them"), "Anna")
        XCTAssertEqual(doc.label(for: "me"), "Me")
        XCTAssertEqual(doc.exportBaseName, "2026.09.26-1030 Weekly sync")

        let md = doc.markdown()
        XCTAssertTrue(md.contains("**[0:00] Anna:** Hi."))
        XCTAssertTrue(md.contains("calendar_event: \"Weekly sync\""))
        XCTAssertTrue(md.contains("  - \"Anna\"  # anna@x.com"))

        let blocks = NotionPayload.blocks(for: doc)
        let texts = blocks.compactMap { $0["paragraph"]?["rich_text"] }.flatMap { value -> [String] in
            guard case .array(let items) = value else { return [] }
            return items.compactMap { $0["text"]?["content"]?.stringValue }
        }
        XCTAssertTrue(texts.contains("With Joakim, Anna"))
        XCTAssertTrue(texts.contains("Anna: "))

        // Old transcripts without the field still decode.
        let decoded = try TranscriptDocument.decode(from: doc.jsonData())
        XCTAssertEqual(decoded, doc)
    }

    func testNoCalendarKeepsDefaults() {
        let doc = TranscriptDocument.build(
            session: .init(id: "s", title: "t", started_at: nil, ended_at: nil, duration_seconds: nil, timezone: "UTC"),
            engine: .init(name: "p", model: "m", vocabulary: false, echo_filter: true, echo_words_removed: 0),
            createdAt: "x",
            words: ["them": [TimedWord(text: "Hi.", start: 0, end: 0.3)]]
        )
        XCTAssertEqual(doc.label(for: "them"), "Them")
        XCTAssertEqual(doc.exportBaseName, "s")
    }
}
