import Foundation
import MysliCore

/// The live transcript of one recording: finished lines per speaker plus the
/// utterance each speaker is in the middle of. Mirrors finished lines to
/// `live.md` in the session folder so the draft survives even if the final
/// transcription never runs.
@MainActor
final class LiveTranscript {
    enum Speaker: String, Sendable {
        case me, them
    }

    struct Line {
        let speaker: Speaker
        let startedAt: Date
        let text: String
    }

    let recordingStartedAt: Date
    private let fileURL: URL
    private let dedupeEcho: Bool
    private let echo = EchoFilter()
    /// Lines further apart than this are never compared for echo.
    private let echoWindow: TimeInterval = 8

    private(set) var lines: [Line] = []
    private(set) var partials: [Speaker: String] = [:]
    /// Shown above the transcript: model loading, unavailability, stopped.
    private(set) var status: String?

    var onChange: (() -> Void)?

    /// The other person's name once the calendar lookup finds a 1:1.
    var themName: String? {
        didSet { onChange?() }
    }

    func label(_ speaker: Speaker) -> String {
        speaker == .me ? "Me" : (themName ?? "Them")
    }

    init(sessionDir: URL, recordingStartedAt: Date, dedupeEcho: Bool) {
        self.fileURL = sessionDir.appendingPathComponent("live.md")
        self.recordingStartedAt = recordingStartedAt
        self.dedupeEcho = dedupeEcho
    }

    func handle(_ speaker: Speaker, _ event: LiveEvent) {
        switch event {
        case .partial(let text):
            partials[speaker] = text
        case .finished(let text, let startedAt):
            partials[speaker] = nil
            finish(speaker, text: text, startedAt: startedAt)
        }
        onChange?()
    }

    func setStatus(_ text: String?) {
        status = text
        onChange?()
    }

    /// The mic partial, unless it is only the far end bleeding in.
    var visibleMicPartial: String? {
        guard let text = partials[.me], !text.isEmpty else { return nil }
        guard dedupeEcho else { return text }
        let reference = recentText(of: .them, around: Date()) + " " + (partials[.them] ?? "")
        return echo.isEcho(line: text, of: reference) ? nil : text
    }

    // MARK: -

    private func finish(_ speaker: Speaker, text: String, startedAt: Date) {
        if dedupeEcho {
            switch speaker {
            case .me:
                // Their line usually finishes first; the echo arrives after.
                let reference = recentText(of: .them, around: startedAt) + " " + (partials[.them] ?? "")
                if echo.isEcho(line: text, of: reference) { return }
            case .them:
                // Or the echo finished first: retract it now.
                lines.removeAll {
                    $0.speaker == .me
                        && abs($0.startedAt.timeIntervalSince(startedAt)) <= echoWindow
                        && echo.isEcho(line: $0.text, of: text)
                }
            }
        }
        let line = Line(speaker: speaker, startedAt: startedAt, text: text)
        let index = lines.lastIndex { $0.startedAt <= startedAt }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
        save()
    }

    private func recentText(of speaker: Speaker, around date: Date) -> String {
        lines.filter {
            $0.speaker == speaker && abs($0.startedAt.timeIntervalSince(date)) <= echoWindow
        }
        .map(\.text)
        .joined(separator: " ")
    }

    func timestamp(_ date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(recordingStartedAt)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Rewrite live.md atomically. Cheap at meeting scale, and a rewrite
    /// (rather than an append) keeps retracted echo lines out of the file.
    private func save() {
        var out = ["# live transcript (draft)", ""]
        for line in lines {
            out.append("**[\(timestamp(line.startedAt))] \(label(line.speaker)):** \(line.text)")
            out.append("")
        }
        try? Data(out.joined(separator: "\n").utf8).write(to: fileURL, options: .atomic)
    }
}
