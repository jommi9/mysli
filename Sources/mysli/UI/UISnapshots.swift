import AppKit
import ArgumentParser
import MysliCore
import SwiftUI

/// `mysli snapshot-ui <dir>`: renders the windows with sample data to PNGs
/// in light and dark mode. Used by CI to check the UI without a person at
/// the Mac; hidden from --help.
struct SnapshotUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot-ui",
        abstract: "Render UI screenshots with sample data.",
        shouldDisplay: false
    )

    @Argument(help: "Output folder.")
    var out: String

    func run() throws {
        let dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try MainActor.assumeIsolated {
            try UISnapshots.renderAll(to: dir)
        }
    }
}

@MainActor
enum UISnapshots {
    static func renderAll(to dir: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"

            let ready = sampleState()
            try render(MainView(state: ready), size: NSSize(width: 960, height: 620), dark: dark,
                       to: dir.appendingPathComponent("main-\(suffix).png"))

            let recording = sampleState()
            recording.isRecording = true
            recording.elapsed = "12:48"
            recording.selection = recording.meetings.first { $0.status == .recording }?.id
            try render(MainView(state: recording), size: NSSize(width: 960, height: 620), dark: dark,
                       to: dir.appendingPathComponent("recording-\(suffix).png"))

            let settings = SettingsModel()
            settings.exportFolders = [URL(fileURLWithPath: NSHomeDirectory() + "/Library/CloudStorage/GoogleDrive-you@gmail.com/My Drive/Meetings")]
            settings.notionDatabaseID = "1f2e3d4c5b6a79881f2e3d4c5b6a7988"
            try render(
                SettingsView(model: settings, recordingsRoot: URL(fileURLWithPath: NSHomeDirectory() + "/Recordings")) {},
                size: NSSize(width: 520, height: 720), dark: dark,
                to: dir.appendingPathComponent("settings-\(suffix).png")
            )
        }
    }

    /// Put the view in a real on-screen window, let it lay out, then capture
    /// it with screencapture so the window server composites it exactly as
    /// on screen (macOS 26 glass sidebars and toolbars don't survive an
    /// in-process cacheDisplay). Falls back to cacheDisplay if screencapture
    /// isn't allowed.
    private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, to url: URL) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "mysli"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.level = .floating
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? capture.run()
        capture.waitUntilExit()

        if capture.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            print("screencapture failed (\(capture.terminationStatus)), using cacheDisplay")
            if let frameView = window.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        window.close()
        print("wrote \(url.lastPathComponent)")
    }

    // MARK: - Sample data

    private static func sampleState() -> AppState {
        let root = URL(fileURLWithPath: "/tmp/mysli-sample")
        let state = AppState(recordingsRoot: root)
        let now = Date()
        let calendar = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let meetings = [
            Meeting(id: "rec", dir: root.appendingPathComponent("rec"), started: now.addingTimeInterval(-768),
                    durationSeconds: nil, status: .recording),
            Meeting(id: "a", dir: root.appendingPathComponent("a"), started: at(0, 10, 30),
                    durationSeconds: 1_860, status: .ready),
            Meeting(id: "b", dir: root.appendingPathComponent("b"), started: at(0, 9, 0),
                    durationSeconds: 1_320, status: .exportFailed),
            Meeting(id: "c", dir: root.appendingPathComponent("c"), started: at(1, 16, 0),
                    durationSeconds: 2_700, status: .ready),
            Meeting(id: "d", dir: root.appendingPathComponent("d"), started: at(1, 11, 15),
                    durationSeconds: 900, status: .transcribing),
        ]
        state.load(meetings: meetings, documents: ["a": sampleDocument(started: at(0, 10, 30))])
        state.selection = "a"
        return state
    }

    private static func sampleDocument(started: Date) -> TranscriptDocument {
        let lines: [(String, String)] = [
            ("them", "Hey, thanks for making time. How is the Hyperliquid integration going?"),
            ("me", "Pretty well. The order routing is done and we started testing withdrawals yesterday."),
            ("them", "Nice. Any issues with the bridge?"),
            ("me", "One. Deposits over about fifty thousand take two confirmations longer than we expected, so the UI shows pending for a while."),
            ("them", "That's fine for launch as long as the status is clear. Can we put an estimate in the pending state?"),
            ("me", "Yes, I'll add an estimated time next to the spinner. Should be done by Thursday."),
            ("them", "Great. Then the last thing is the audit. EigenLayer asked for the final report before they list us."),
            ("me", "The auditors promised it Monday. I'll forward it the same day."),
        ]
        var words: [String: [TimedWord]] = [:]
        var t: TimeInterval = 2
        for (speaker, text) in lines {
            for w in text.split(separator: " ") {
                words[speaker, default: []].append(TimedWord(text: String(w), start: t, end: t + 0.3))
                t += 0.34
            }
            t += 1.6
        }
        let iso = ISO8601DateFormatter()
        return TranscriptDocument.build(
            session: .init(
                id: "2026.09.26-1030",
                title: "Meeting " + started.formatted(date: .numeric, time: .shortened),
                started_at: iso.string(from: started),
                ended_at: iso.string(from: started.addingTimeInterval(1_860)),
                duration_seconds: 1_860,
                timezone: TimeZone.current.identifier
            ),
            engine: .init(name: "parakeet", model: "parakeet-tdt-0.6b-v2-coreml",
                          vocabulary: true, echo_filter: true, echo_words_removed: 12),
            createdAt: iso.string(from: Date()),
            words: words
        )
    }
}
