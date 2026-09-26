import Foundation

/// API tokens, kept out of the config file.
enum Secrets {
    /// Keychain service name for the Notion integration token. Store it with
    ///
    ///     security add-generic-password -s mysli.notion -a notion -w
    ///
    /// (prompts for the token, so it never lands in shell history).
    static let notionKeychainService = "mysli.notion"

    /// `MYSLI_NOTION_TOKEN` if set, else the Keychain item. Reading through
    /// /usr/bin/security keeps the item's access list pointing at an
    /// Apple-signed tool, so rebuilding mysli doesn't trigger a new Keychain
    /// prompt.
    static func notionToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["MYSLI_NOTION_TOKEN"], !env.isEmpty {
            return env
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", notionKeychainService, "-w"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
