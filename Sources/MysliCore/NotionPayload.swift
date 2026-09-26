import Foundation

/// A JSON value, for building API payloads that encode deterministically
/// and can be compared in tests.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// Request bodies for writing a transcript into a Notion database. Pure
/// data; the HTTP client lives in the app.
public enum NotionPayload {
    /// Notion rejects a rich-text item over 2000 characters.
    public static let maxTextLength = 2000
    /// ...and more than 100 blocks per request.
    public static let maxBlocksPerRequest = 100

    /// Properties for the new database row: the title, plus the start date if
    /// the database has a date property.
    public static func properties(
        document: TranscriptDocument,
        titleProperty: String,
        dateProperty: String?
    ) -> JSONValue {
        var props: [String: JSONValue] = [
            titleProperty: .object(["title": .array(richText(document.session.title))]),
        ]
        if let dateProperty, let start = document.session.started_at {
            var date: [String: JSONValue] = ["start": .string(start)]
            if let end = document.session.ended_at { date["end"] = .string(end) }
            props[dateProperty] = .object(["date": .object(date)])
        }
        return .object(props)
    }

    /// The page body: a summary line, a divider, then one paragraph per
    /// segment ("0:12  Me: text").
    public static func blocks(for document: TranscriptDocument) -> [JSONValue] {
        var blocks: [JSONValue] = []
        let summary = document.summaryLine
        if !summary.isEmpty {
            blocks.append(paragraph(richText(summary, italic: true, color: "gray")))
        }
        blocks.append(.object(["object": .string("block"), "type": .string("divider"), "divider": .object([:])]))
        for seg in document.segments {
            var rich = richText(TranscriptDocument.clock(seg.start_ms) + "  ", color: "gray")
            rich += richText(TranscriptDocument.speakerLabel(seg.speaker) + ": ", bold: true)
            rich += richText(seg.text)
            blocks.append(paragraph(rich))
        }
        return blocks
    }

    /// Split into request-sized batches.
    public static func batches<T>(_ items: [T], size: Int = maxBlocksPerRequest) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    /// Rich-text items for `text`, split under Notion's length limit on word
    /// boundaries where possible.
    public static func richText(
        _ text: String,
        bold: Bool = false,
        italic: Bool = false,
        color: String = "default"
    ) -> [JSONValue] {
        chunks(text, limit: maxTextLength).map { chunk in
            .object([
                "type": .string("text"),
                "text": .object(["content": .string(chunk)]),
                "annotations": .object([
                    "bold": .bool(bold),
                    "italic": .bool(italic),
                    "color": .string(color),
                ]),
            ])
        }
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        // Notion counts UTF-16 code units.
        guard text.utf16.count > limit else { return [text] }
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let piece = current.isEmpty ? String(word) : " " + word
            if current.utf16.count + piece.utf16.count <= limit {
                current += piece
                continue
            }
            if !current.isEmpty { out.append(current) }
            // A single word longer than the limit is cut hard.
            var rest = String(word)
            while rest.utf16.count > limit {
                let cut = rest.index(rest.startIndex, offsetBy: limit / 2)
                out.append(String(rest[..<cut]))
                rest = String(rest[cut...])
            }
            current = rest
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func paragraph(_ rich: [JSONValue]) -> JSONValue {
        .object([
            "object": .string("block"),
            "type": .string("paragraph"),
            "paragraph": .object(["rich_text": .array(rich)]),
        ])
    }
}
