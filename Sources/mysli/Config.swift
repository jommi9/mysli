import FluidAudio
import Foundation

/// Optional user config at ~/.config/mysli/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "parakeet",
///         "model": "v2",
///         "echo_filter": true,
///         "vocabulary": "~/.config/mysli/vocabulary.txt"
///       },
///       "live": { "enabled": true, "show_window": true },
///       "system_audio": { "exclude_apps": ["com.spotify.client"], "only_apps": [] },
///       "exports": {
///         "folders": ["~/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Meetings"],
///         "notion": { "database_id": "…" }
///       },
///       "mic_voice_processing": false,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mysli", isDirectory: true)

    static let path = directory.appendingPathComponent("config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    // MARK: - Transcription

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    /// Parakeet model: "v2" (English, default, best English recall) or "v3"
    /// (25 European languages including Finnish, auto-detected).
    static func parakeetVersion() -> AsrModelVersion {
        switch transcription()?["model"] as? String {
        case "v3"?: return .v3
        case nil, "v2"?: return .v2
        case let other?:
            FileHandle.standardError.write(Data(
                "warning: unknown parakeet model \"\(other)\" — using v2\n".utf8
            ))
            return .v2
        }
    }

    /// Drop far-end speech that bled into the mic from the final transcript.
    /// Default on; it only fires on runs of words the system track also has
    /// at the same moment, so on headphones it has nothing to do.
    static func echoFilterEnabled() -> Bool {
        transcription()?["echo_filter"] as? Bool ?? true
    }

    /// Custom vocabulary for boosting rare terms, if the file exists.
    /// Defaults to ~/.config/mysli/vocabulary.txt.
    static func vocabularyFile() -> URL? {
        let url: URL
        if let configured = transcription()?["vocabulary"] as? String, !configured.isEmpty {
            url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        } else {
            url = directory.appendingPathComponent("vocabulary.txt")
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    // MARK: - Live transcript

    /// Stream both tracks through a small streaming model while recording.
    /// Default on. The final transcript is still produced from the files.
    static func liveEnabled() -> Bool {
        live()?["enabled"] as? Bool ?? true
    }

    /// Open the live transcript window when a recording starts. Default on.
    static func liveShowWindow() -> Bool {
        live()?["show_window"] as? Bool ?? true
    }

    private static func live() -> [String: Any]? {
        load()?["live"] as? [String: Any]
    }

    // MARK: - System audio

    /// Bundle-id prefixes whose audio is left out of the system track. The
    /// defaults are media players, whose audio is never the meeting.
    static let defaultExcludedApps = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    static func systemAudioExcludedApps() -> [String] {
        systemAudio()?["exclude_apps"] as? [String] ?? defaultExcludedApps
    }

    /// When non-empty, record only these apps (bundle-id prefixes) instead of
    /// everything minus the exclusions. Default empty.
    static func systemAudioOnlyApps() -> [String] {
        systemAudio()?["only_apps"] as? [String] ?? []
    }

    private static func systemAudio() -> [String: Any]? {
        load()?["system_audio"] as? [String: Any]
    }

    // MARK: - Exports

    /// Folders that get a copy of every transcript (Markdown + JSON). A
    /// Google Drive, Dropbox or iCloud folder syncs them onward; an Obsidian
    /// vault indexes them. Each folder must already exist.
    static func exportFolders() -> [URL] {
        (exports()?["folders"] as? [String] ?? [])
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Notion database that gets a page per transcript. The integration
    /// token is read from the Keychain (see `Secrets`).
    static func notionDatabaseID() -> String? {
        guard let notion = exports()?["notion"] as? [String: Any],
              let id = notion["database_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    private static func exports() -> [String: Any]? {
        load()?["exports"] as? [String: Any]
    }

    // MARK: - Mic

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Read-modify-write the config file, keeping keys the caller doesn't
    /// touch. Settings take effect on the next recording or transcription,
    /// since every accessor rereads the file.
    static func update(_ mutate: (inout [String: Any]) -> Void) throws {
        var json = load() ?? [:]
        mutate(&json)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: path, options: .atomic)
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
