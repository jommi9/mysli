import AppKit
import ArgumentParser
import Foundation
import os

@main
struct Mysli: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mysli",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Doctor.self, Install.self, Export.self, SnapshotUI.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(name: .long, help: "Start in the menu bar without opening the window (used at login).")
    var background = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)
        if !background {
            controller.showWindow()
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "mysli up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export transcribed sessions to the configured folders and Notion.",
        discussion: """
        New transcripts export automatically. Use this to backfill older
        sessions after adding a destination. Destinations a session was
        already exported to are skipped.
        """
    )

    @Argument(help: "Session folders, e.g. ~/Recordings/2026.09.26-1400")
    var sessions: [String]

    func run() throws {
        guard !Exporter.configuredTargets().isEmpty else {
            FileHandle.standardError.write(Data("no exports configured in \(Config.path.path)\n".utf8))
            throw ExitCode(64)
        }
        let dirs = sessions.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        // ArgumentParser's sync entry point: run the async export on a
        // detached task and wait for it.
        let done = DispatchSemaphore(value: 0)
        let failed = OSAllocatedUnfairLock(initialState: 0)
        Task.detached {
            for dir in dirs {
                let failures = await Exporter.run(dir: dir) { print("\(dir.lastPathComponent): \($0)") }
                failed.withLock { $0 += failures.count }
            }
            done.signal()
        }
        done.wait()
        if failed.withLock({ $0 }) > 0 { throw ExitCode(1) }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let liveWindow = LiveTranscriptWindow()
    private let state: AppState
    private let mainWindow: MainWindowController
    private var session: RecordingSession?
    private var live: LiveSession?
    private var liveTranscript: LiveTranscript?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        state = AppState(recordingsRoot: root)
        mainWindow = MainWindowController(state: state)
        MainWindowController.installMainMenu { [weak self] in self?.shutdown() }
        state.onToggleRecording = { [weak self] in self?.toggle() }
        state.onShowLive = { [weak self] in self?.liveWindow.show() }
        menuBar.onOpenWindow = { [weak self] in self?.mainWindow.show() }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onShowLive = { [weak self] in self?.liveWindow.show() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    func showWindow() {
        mainWindow.show()
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            liveTranscript = nil
            let newLive = Config.liveEnabled() ? startLive(for: newSession) : nil
            do {
                try newSession.start()
            } catch {
                if let newLive { Task { await newLive.finish() } }
                throw error
            }
            session = newSession
            live = newLive
            state.isRecording = true
            state.elapsed = "0:00"
            state.recordingSession = newSession.dir.lastPathComponent
            state.refresh()
            state.selection = newSession.dir.lastPathComponent
            lookUpCalendar(for: newSession)
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "mysli — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Set up the live transcript for a session that is about to start.
    private func startLive(for session: RecordingSession) -> LiveSession {
        let transcript = LiveTranscript(
            sessionDir: session.dir,
            recordingStartedAt: session.startedAt,
            dedupeEcho: Config.echoFilterEnabled()
        )
        liveTranscript = transcript
        let live = LiveSession(transcript: transcript)
        session.attachLive(live)
        liveWindow.attach(transcript)
        if Config.liveShowWindow() {
            liveWindow.show()
        }
        return live
    }

    /// Match the recording to its calendar event in the background: the
    /// meeting title and, in a 1:1, the other person's name for "Them".
    /// Transcription repeats the lookup if this one hasn't finished.
    private func lookUpCalendar(for session: RecordingSession) {
        let dir = session.dir
        let started = session.startedAt
        let transcript = liveTranscript
        Task { @MainActor [weak self] in
            guard let info = await CalendarLookup.meeting(around: started) else { return }
            SessionCalendar.write(info, to: dir)
            transcript?.themName = info.otherPersonName
            self?.state.refresh()
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        if let live {
            self.live = nil
            // The recorders have stopped, so the feeds are complete. The
            // final transcript doesn't wait on the live one.
            Task { await live.finish() }
        }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        state.isRecording = false
        state.recordingSession = nil
        state.refresh()
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        if case .transcribing(let name, _) = status {
            state.transcribingSession = name
        } else {
            state.transcribingSession = nil
        }
        state.refresh()
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
        state.elapsed = elapsed
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
