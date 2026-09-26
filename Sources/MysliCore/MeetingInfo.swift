import Foundation

/// The calendar event a recording belongs to, as saved in the session's
/// calendar.json and embedded in transcript.json.
public struct MeetingInfo: Codable, Sendable, Equatable {
    public struct Attendee: Codable, Sendable, Equatable {
        public var name: String?
        public var email: String?
        /// The calendar owner, i.e. you.
        public var is_self: Bool

        public init(name: String?, email: String?, is_self: Bool) {
            self.name = name
            self.email = email
            self.is_self = is_self
        }

        /// Name if known, else the email's local part ("anna.k@x.com" → "anna.k").
        public var displayName: String? {
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty,
               name.lowercased() != email?.lowercased() {
                return name
            }
            return email.map { String($0.split(separator: "@").first ?? Substring($0)) }
        }
    }

    public var title: String
    public var starts_at: String
    public var ends_at: String
    public var organizer: String?
    public var attendees: [Attendee]

    public init(title: String, starts_at: String, ends_at: String, organizer: String?, attendees: [Attendee]) {
        self.title = title
        self.starts_at = starts_at
        self.ends_at = ends_at
        self.organizer = organizer
        self.attendees = attendees
    }

    /// The other person in a 1:1: the single attendee who isn't you. Nil for
    /// group meetings or events without a guest list, where "Them" stays.
    public var otherPersonName: String? {
        let others = attendees.filter { !$0.is_self }
        guard others.count == 1 else { return nil }
        return others[0].displayName
    }

    public static func decode(from data: Data) throws -> MeetingInfo {
        try JSONDecoder().decode(MeetingInfo.self, from: data)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Picks the event a recording belongs to.
public enum MeetingMatcher {
    public struct Candidate: Sendable, Equatable {
        public let start: Date
        public let end: Date
        public let isAllDay: Bool
        public let attendeeCount: Int

        public init(start: Date, end: Date, isAllDay: Bool, attendeeCount: Int) {
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.attendeeCount = attendeeCount
        }
    }

    /// Index of the best event for a recording that started at `recording`,
    /// or nil. An event qualifies if it isn't all-day and the recording
    /// started between `earlyStart` before it and its end (people often hit
    /// record a few minutes early, or join late). Among those, events with
    /// guests beat solo blocks ("Focus time"), then the one whose start is
    /// closest to when recording began.
    public static func bestMatch(
        for recording: Date,
        in candidates: [Candidate],
        earlyStart: TimeInterval = 10 * 60
    ) -> Int? {
        let eligible = candidates.indices.filter { i in
            let c = candidates[i]
            return !c.isAllDay
                && recording >= c.start.addingTimeInterval(-earlyStart)
                && recording < c.end
        }
        return eligible.min { a, b in
            let ca = candidates[a], cb = candidates[b]
            let guestsA = ca.attendeeCount > 0, guestsB = cb.attendeeCount > 0
            if guestsA != guestsB { return guestsA }
            return abs(ca.start.timeIntervalSince(recording)) < abs(cb.start.timeIntervalSince(recording))
        }
    }

    /// A string safe to use in a file name: no path separators or
    /// characters Finder and Drive reject, whitespace collapsed, capped at
    /// `maxLength`.
    public static func fileSafe(_ s: String, maxLength: Int = 60) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }
}
