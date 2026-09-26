import Foundation

/// The canonical transcript of one recording, written as transcript.json.
///
/// Property names are the JSON schema (snake_case on purpose). The schema is
/// versioned in `schema` so downstream tools can tell layouts apart; bump it
/// on any breaking change.
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public static let currentSchema = "mysli.transcript/2"

    public var schema: String
    public var session: Session
    public var engine: Engine
    /// When this transcript was produced (ISO 8601, local offset).
    public var created_at: String
    public var speakers: [Speaker]
    public var segments: [Segment]

    public struct Session: Codable, Sendable, Equatable {
        /// The session folder name, e.g. "2026.09.26-1400". Stable and unique.
        public var id: String
        public var title: String
        public var started_at: String?
        public var ended_at: String?
        public var duration_seconds: Int?
        /// IANA zone the times were rendered in, e.g. "Europe/Berlin".
        public var timezone: String
        /// The calendar event the recording matched, if any.
        public var calendar: MeetingInfo?

        public init(
            id: String, title: String, started_at: String?, ended_at: String?,
            duration_seconds: Int?, timezone: String, calendar: MeetingInfo? = nil
        ) {
            self.id = id
            self.title = title
            self.started_at = started_at
            self.ended_at = ended_at
            self.duration_seconds = duration_seconds
            self.timezone = timezone
            self.calendar = calendar
        }
    }

    public struct Engine: Codable, Sendable, Equatable {
        public var name: String
        public var model: String
        public var vocabulary: Bool
        public var echo_filter: Bool
        /// Mic words dropped as far-end echo.
        public var echo_words_removed: Int

        public init(name: String, model: String, vocabulary: Bool, echo_filter: Bool, echo_words_removed: Int) {
            self.name = name
            self.model = model
            self.vocabulary = vocabulary
            self.echo_filter = echo_filter
            self.echo_words_removed = echo_words_removed
        }
    }

    public struct Speaker: Codable, Sendable, Equatable {
        /// "me" or "them"; matches `Segment.speaker`.
        public var id: String
        public var label: String
        /// Which recording the speaker came from: "microphone" or "system_audio".
        public var source: String
        /// Summed segment durations.
        public var talk_seconds: Double
        /// Fraction of all talk time, 0...1.
        public var talk_share: Double
        public var word_count: Int
        public var segment_count: Int
    }

    public struct Segment: Codable, Sendable, Equatable {
        /// Position in the merged transcript, from 0.
        public var id: Int
        public var speaker: String
        public var start_ms: Int
        public var end_ms: Int
        public var text: String
        public var words: [Word]
    }

    public struct Word: Codable, Sendable, Equatable {
        public var text: String
        public var start_ms: Int
        public var end_ms: Int
    }
}

// MARK: - Building

extension TranscriptDocument {
    public static func speakerLabel(_ id: String) -> String {
        switch id {
        case "me": return "Me"
        case "them": return "Them"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private static func source(_ id: String) -> String {
        switch id {
        case "me": return "microphone"
        case "them": return "system_audio"
        default: return "unknown"
        }
    }

    /// Segment each speaker's words, merge by time and compute per-speaker
    /// stats.
    ///
    /// - Parameter words: session-clock words keyed by speaker id.
    public static func build(
        session: Session,
        engine: Engine,
        createdAt: String,
        words: [String: [TimedWord]]
    ) -> TranscriptDocument {
        var segments: [Segment] = []
        for (speaker, trackWords) in words {
            segments += Segmenter.segments(from: trackWords).map { seg in
                Segment(
                    id: 0,
                    speaker: speaker,
                    start_ms: ms(seg.start),
                    end_ms: ms(seg.end),
                    text: seg.text,
                    words: seg.words.map { Word(text: $0.text, start_ms: ms($0.start), end_ms: ms($0.end)) }
                )
            }
        }
        segments.sort { ($0.start_ms, $0.speaker) < ($1.start_ms, $1.speaker) }
        for i in segments.indices { segments[i].id = i }

        // "me" first, then "them", then anything else alphabetically.
        let order = ["me": 0, "them": 1]
        let ids = words.keys.sorted { (order[$0] ?? 2, $0) < (order[$1] ?? 2, $1) }
        let talk = Dictionary(grouping: segments, by: \.speaker).mapValues { segs in
            segs.reduce(0.0) { $0 + Double($1.end_ms - $1.start_ms) / 1000 }
        }
        let totalTalk = talk.values.reduce(0, +)
        let speakers = ids.map { id in
            let segs = segments.filter { $0.speaker == id }
            let seconds = talk[id] ?? 0
            // In a 1:1 with a calendar invite, "them" is one known person.
            let label = id == "them" ? session.calendar?.otherPersonName ?? speakerLabel(id) : speakerLabel(id)
            return Speaker(
                id: id,
                label: label,
                source: source(id),
                talk_seconds: (seconds * 10).rounded() / 10,
                talk_share: totalTalk > 0 ? ((seconds / totalTalk) * 1000).rounded() / 1000 : 0,
                word_count: segs.reduce(0) { $0 + $1.words.count },
                segment_count: segs.count
            )
        }

        return TranscriptDocument(
            schema: currentSchema,
            session: session,
            engine: engine,
            created_at: createdAt,
            speakers: speakers,
            segments: segments
        )
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}

// MARK: - Turns

extension TranscriptDocument {
    /// Consecutive segments from one speaker, read as a single paragraph.
    public struct Turn: Sendable, Equatable {
        public let speaker: String
        public let start_ms: Int
        public let end_ms: Int
        public let text: String
        public let segmentIDs: [Int]
    }

    /// Segments are sentence-sized, which reads choppy with a speaker label
    /// on every line. A turn merges a speaker's consecutive segments until
    /// the other speaker talks or there's a pause longer than `maxGapMs`.
    public func turns(maxGapMs: Int = 4_000) -> [Turn] {
        var out: [Turn] = []
        for seg in segments {
            if let last = out.last, last.speaker == seg.speaker, seg.start_ms - last.end_ms <= maxGapMs {
                out[out.count - 1] = Turn(
                    speaker: last.speaker,
                    start_ms: last.start_ms,
                    end_ms: max(last.end_ms, seg.end_ms),
                    text: last.text + " " + seg.text,
                    segmentIDs: last.segmentIDs + [seg.id]
                )
            } else {
                out.append(Turn(
                    speaker: seg.speaker, start_ms: seg.start_ms, end_ms: seg.end_ms,
                    text: seg.text, segmentIDs: [seg.id]
                ))
            }
        }
        return out
    }
}

// MARK: - Rendering

extension TranscriptDocument {
    /// Display label for a speaker id: the other person's name when the
    /// calendar knew it, else "Me" / "Them".
    public func label(for speaker: String) -> String {
        speakers.first { $0.id == speaker }?.label ?? Self.speakerLabel(speaker)
    }

    /// File name (without extension) for exports: the session id, plus the
    /// meeting title when the calendar gave one, so folders sort by time and
    /// still read well.
    public var exportBaseName: String {
        guard let title = session.calendar?.title else { return session.id }
        let safe = MeetingMatcher.fileSafe(title)
        return safe.isEmpty ? session.id : "\(session.id) \(safe)"
    }

    /// Pretty-printed JSON with stable key order.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> TranscriptDocument {
        try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }

    /// "12:05" or "1:02:03" from milliseconds.
    public static func clock(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// One line summary: "42 min · Me 55% · Them 45%".
    public var summaryLine: String {
        var parts: [String] = []
        if let seconds = session.duration_seconds {
            parts.append("\(max(1, Int((Double(seconds) / 60).rounded()))) min")
        }
        for s in speakers where s.talk_seconds > 0 {
            parts.append("\(s.label) \(Int((s.talk_share * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// Markdown with YAML front matter, readable as-is and parseable by
    /// Obsidian, static-site tools and LLM pipelines.
    public func markdown() -> String {
        var fm = ["---"]
        fm.append("title: \(yaml(session.title))")
        fm.append("session_id: \(yaml(session.id))")
        if let started = session.started_at { fm.append("date: \(started)") }
        if let ended = session.ended_at { fm.append("ended: \(ended)") }
        if let seconds = session.duration_seconds { fm.append("duration_seconds: \(seconds)") }
        fm.append("timezone: \(yaml(session.timezone))")
        if let calendar = session.calendar {
            fm.append("calendar_event: \(yaml(calendar.title))")
            if let organizer = calendar.organizer { fm.append("organizer: \(yaml(organizer))") }
            if !calendar.attendees.isEmpty {
                fm.append("attendees:")
                for a in calendar.attendees {
                    fm.append("  - \(yaml(a.displayName ?? "unknown"))" + (a.email.map { "  # \($0)" } ?? ""))
                }
            }
        }
        fm.append("speakers:")
        for s in speakers {
            fm.append("  - id: \(s.id)")
            fm.append("    label: \(yaml(s.label))")
            fm.append("    source: \(s.source)")
            fm.append("    talk_seconds: \(s.talk_seconds)")
            fm.append("    talk_share: \(s.talk_share)")
            fm.append("    words: \(s.word_count)")
        }
        fm.append("engine: \(yaml(engine.model))")
        fm.append("schema: \(yaml(schema))")
        fm.append("source: mysli")
        fm.append("---")

        var body = ["", "# \(session.title)", ""]
        let summary = summaryLine
        if !summary.isEmpty {
            body.append("_\(summary)_")
            body.append("")
        }
        for turn in turns() {
            body.append("**[\(Self.clock(turn.start_ms))] \(label(for: turn.speaker)):** \(turn.text)")
            body.append("")
        }
        return (fm + body).joined(separator: "\n")
    }

    /// A double-quoted YAML scalar.
    private func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
