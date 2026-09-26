import Foundation
import MysliCore

/// Minimal Notion REST client: enough to create one page per transcript in a
/// database the integration has been shared with.
struct NotionClient: Sendable {
    enum NotionError: Error, CustomStringConvertible {
        case http(Int, String)
        case unexpectedResponse(String)
        case noTitleProperty

        var description: String {
            switch self {
            case .http(let status, let message): return "Notion HTTP \(status): \(message)"
            case .unexpectedResponse(let what): return "unexpected Notion response: \(what)"
            case .noTitleProperty: return "the Notion database has no title property"
            }
        }
    }

    let token: String
    private static let base = URL(string: "https://api.notion.com/v1/")!
    /// Stable API version that still addresses databases directly.
    private static let version = "2022-06-28"

    /// Create the page and fill it, returning its id and URL. If filling
    /// fails partway, the half-written page is archived so a retry doesn't
    /// leave a duplicate behind.
    func createTranscriptPage(databaseID: String, document: TranscriptDocument) async throws -> (id: String, url: String) {
        let database = try await request("GET", "databases/\(databaseID)")
        guard case .object(let properties)? = database["properties"] else {
            throw NotionError.unexpectedResponse("database has no properties")
        }
        // Property names are the user's; find them by type.
        let titleProperty = properties.first { $0.value["type"]?.stringValue == "title" }?.key
        let dateProperty = properties
            .filter { $0.value["type"]?.stringValue == "date" }
            .map(\.key)
            .sorted()
            .first
        guard let titleProperty else { throw NotionError.noTitleProperty }

        let batches = NotionPayload.batches(NotionPayload.blocks(for: document))
        let page = try await request("POST", "pages", body: .object([
            "parent": .object(["database_id": .string(databaseID)]),
            "properties": NotionPayload.properties(
                document: document, titleProperty: titleProperty, dateProperty: dateProperty
            ),
            "children": .array(batches.first ?? []),
        ]))
        guard let pageID = page["id"]?.stringValue else {
            throw NotionError.unexpectedResponse("created page has no id")
        }

        do {
            for batch in batches.dropFirst() {
                _ = try await request("PATCH", "blocks/\(pageID)/children", body: .object([
                    "children": .array(batch),
                ]))
            }
        } catch {
            _ = try? await request("PATCH", "pages/\(pageID)", body: .object(["archived": .bool(true)]))
            throw error
        }
        return (pageID, page["url"]?.stringValue ?? "")
    }

    /// One API call, retrying rate limits (429) and server errors a few
    /// times with the delay Notion asks for.
    private func request(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        var attempt = 0
        while true {
            attempt += 1
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }
            let retryable = status == 429 || status >= 500
            if retryable, attempt < 4 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let delay = header.flatMap(Double.init) ?? Double(attempt * 2)
                try await Task.sleep(nanoseconds: UInt64(min(delay, 30) * 1_000_000_000))
                continue
            }
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["message"]?.stringValue
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw NotionError.http(status, message)
        }
    }
}
