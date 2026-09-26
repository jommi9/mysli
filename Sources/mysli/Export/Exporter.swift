import Foundation
import MysliCore

/// Copies finished transcripts to the configured destinations and records
/// the outcome per destination in the session's exports.json, so a failed
/// export (Drive not mounted, offline, Notion down) is retried on the next
/// launch and a finished one is never repeated.
struct Exporter {
    enum Target {
        case folder(URL)
        case notion(databaseID: String)

        /// Key in exports.json.
        var key: String {
            switch self {
            case .folder(let url): return "folder:\(url.path)"
            case .notion(let id): return "notion:\(id)"
            }
        }
    }

    enum ExportError: Error, CustomStringConvertible {
        case folderMissing(URL)
        case noNotionToken

        var description: String {
            switch self {
            case .folderMissing(let url):
                return "\(url.path) doesn't exist (is Google Drive / the sync app running?)"
            case .noNotionToken:
                return "no Notion token: run `security add-generic-password -s \(Secrets.notionKeychainService) -a notion -w`"
            }
        }
    }

    static func configuredTargets() -> [Target] {
        Config.exportFolders().map(Target.folder)
            + (Config.notionDatabaseID().map { [Target.notion(databaseID: $0)] } ?? [])
    }

    /// Configured targets this session hasn't been exported to yet.
    static func pendingTargets(for dir: URL) -> [Target] {
        let state = readState(dir)
        return configuredTargets().filter { state[$0.key]?["status"]?.stringValue != "done" }
    }

    /// Whether an export was ever attempted for this session. Retries at
    /// launch are limited to these, so configuring a new destination
    /// doesn't upload the whole archive (use `mysli export` for that).
    static func wasAttempted(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("exports.json").path)
    }

    /// Export to every pending target. Returns the failures, already logged.
    @discardableResult
    static func run(dir: URL, log: @Sendable (String) -> Void) async -> [String] {
        let targets = pendingTargets(for: dir)
        guard !targets.isEmpty else { return [] }

        let document: TranscriptDocument
        do {
            let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
            document = try TranscriptDocument.decode(from: data)
        } catch {
            // Transcripts from before the v2 schema can't be exported;
            // re-transcribe by deleting transcript.json.
            log("export skipped: transcript.json isn't \(TranscriptDocument.currentSchema) (\(error))")
            return []
        }

        var state = readState(dir)
        var failures: [String] = []
        for target in targets {
            do {
                let detail = try await export(document, dir: dir, to: target)
                state[target.key] = .object([
                    "status": .string("done"),
                    "at": .string(ISO8601DateFormatter().string(from: Date())),
                    "detail": .string(detail),
                ])
                log("exported → \(detail)")
            } catch {
                state[target.key] = .object([
                    "status": .string("failed"),
                    "at": .string(ISO8601DateFormatter().string(from: Date())),
                    "error": .string("\(error)"),
                ])
                log("export to \(target.key) failed: \(error)")
                failures.append("\(target.key): \(error)")
            }
            writeState(state, dir)
        }
        return failures
    }

    /// Returns a short description of where the transcript went.
    private static func export(_ document: TranscriptDocument, dir: URL, to target: Target) async throws -> String {
        switch target {
        case .folder(let folder):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                throw ExportError.folderMissing(folder)
            }
            let base = document.exportBaseName
            try Data(document.markdown().utf8)
                .write(to: folder.appendingPathComponent("\(base).md"), options: .atomic)
            try document.jsonData()
                .write(to: folder.appendingPathComponent("\(base).json"), options: .atomic)
            return folder.appendingPathComponent("\(base).md").path

        case .notion(let databaseID):
            guard let token = Secrets.notionToken() else { throw ExportError.noNotionToken }
            let page = try await NotionClient(token: token)
                .createTranscriptPage(databaseID: databaseID, document: document)
            return page.url.isEmpty ? "notion page \(page.id)" : page.url
        }
    }

    // MARK: - exports.json

    private static func readState(_ dir: URL) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("exports.json")),
              case .object(let state)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [:] }
        return state
    }

    private static func writeState(_ state: [String: JSONValue], _ dir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(JSONValue.object(state)) {
            try? data.write(to: dir.appendingPathComponent("exports.json"), options: .atomic)
        }
    }
}
