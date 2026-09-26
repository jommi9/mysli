import Foundation
import MysliCore

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's words are shifted by its
/// start offset, echo of the far end is dropped from the mic words, and both
/// tracks are segmented, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        // Untranscribed sessions, plus transcribed ones whose export failed
        // last time (only sessions an export was attempted for, so adding a
        // destination doesn't upload the whole archive).
        let pending = entries
            .filter {
                guard fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) else { return false }
                if !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) { return true }
                return Exporter.wasAttempted($0) && !Exporter.pendingTargets(for: $0).isEmpty
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) session(s) needing transcription or export\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                let transcriptURL = dir.appendingPathComponent("transcript.json")
                let needsTranscript = !FileManager.default.fileExists(atPath: transcriptURL.path)
                if needsTranscript {
                    try await transcribe(dir)
                }
                let failures = await Exporter.run(dir: dir) { [self] in self.log(dir, $0) }
                if !failures.isEmpty {
                    notifyUser(
                        title: "mysli — export failed",
                        body: "\(dir.lastPathComponent) — retries on next launch, see transcribe.log"
                    )
                }
                if needsTranscript {
                    notifyUser(title: "mysli — transcript ready", body: dir.lastPathComponent)
                    runHook(for: dir)
                }
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "mysli — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        // Words per speaker, shifted onto the session clock.
        var words: [String: [TimedWord]] = [:]
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name) · \(engine.model))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            do {
                let offset = TimeInterval(track.offsetMs) / 1000
                words[track.speaker] = try await engine.transcribe(audio).map { $0.shifted(by: offset) }
            } catch {
                log(dir, "skipping \(track.file): \(error)")
            }
        }

        // Speaker bleed: without headphones the mic hears the far end, so
        // their words would appear twice, once as "me". The system track is
        // the clean reference.
        var echoRemoved = 0
        if Config.echoFilterEnabled(), let mic = words["me"], let system = words["them"] {
            let result = EchoFilter().removeEcho(mic: mic, system: system)
            echoRemoved = result.removed.count
            if !result.removed.isEmpty {
                log(dir, "echo filter: dropped \(result.removed.count) of \(mic.count) mic words")
            }
            words["me"] = result.kept
        }

        // Normally written when recording started; look it up now for
        // sessions where that didn't finish (or predates the feature).
        var calendar = SessionCalendar.read(from: dir)
        if calendar == nil, let started = meta.started {
            calendar = await CalendarLookup.meeting(around: started)
            if let calendar { SessionCalendar.write(calendar, to: dir) }
        }

        let document = TranscriptDocument.build(
            session: meta.session(id: dir.lastPathComponent, calendar: calendar),
            engine: .init(
                name: engine.name,
                model: engine.model,
                vocabulary: Config.vocabularyFile() != nil,
                echo_filter: Config.echoFilterEnabled(),
                echo_words_removed: echoRemoved
            ),
            createdAt: SessionMeta.localISO(Date()),
            words: words
        )
        // Both writes are atomic (temp file + rename), so a partial
        // transcript never exists on disk; resumePending treats
        // transcript.json as "done".
        try document.jsonData().write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(document.markdown().utf8).write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        log(dir, "done — \(document.segments.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine(
            version: Config.parakeetVersion(),
            vocabularyURL: Config.vocabularyFile()
        )
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    nonisolated private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, how far each track started after the earliest one, and when
/// the session ran.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]
    let started: Date?
    let ended: Date?
    let durationSeconds: Int?

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        let iso = ISO8601DateFormatter()
        return SessionMeta(
            tracks: tracks,
            started: (json["started"] as? String).flatMap(iso.date(from:)),
            ended: (json["ended"] as? String).flatMap(iso.date(from:)),
            durationSeconds: json["duration_seconds"] as? Int
        )
    }

    /// Session block for the transcript, times in the Mac's local zone.
    func session(id: String, calendar: MeetingInfo?) -> TranscriptDocument.Session {
        TranscriptDocument.Session(
            id: id,
            title: calendar?.title ?? started.map(Self.title) ?? id,
            started_at: started.map(Self.localISO),
            ended_at: ended.map(Self.localISO),
            duration_seconds: durationSeconds,
            timezone: TimeZone.current.identifier,
            calendar: calendar
        )
    }

    /// ISO 8601 with the local UTC offset, e.g. 2026-09-26T14:00:00+02:00.
    static func localISO(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func title(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "Meeting \(f.string(from: date))"
    }
}
