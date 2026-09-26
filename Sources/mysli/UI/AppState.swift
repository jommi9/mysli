import AppKit
import Foundation
import MysliCore
import Observation

/// One recording as the main window lists it. Built from meta.json and file
/// presence only; the transcript itself loads when the meeting is opened.
struct Meeting: Identifiable, Equatable {
    enum Status: Equatable {
        case recording
        case transcribing
        case waiting
        case ready
        case exportFailed
    }

    let id: String
    let dir: URL
    let started: Date?
    let durationSeconds: Int?
    var status: Status

    var title: String {
        guard let started else { return id }
        return started.formatted(date: .omitted, time: .shortened)
    }

    var subtitle: String {
        var parts: [String] = []
        if let durationSeconds {
            parts.append("\(max(1, Int((Double(durationSeconds) / 60).rounded()))) min")
        }
        switch status {
        case .recording: parts.append("recording")
        case .transcribing: parts.append("transcribing…")
        case .waiting: parts.append("not transcribed yet")
        case .exportFailed: parts.append("export failed")
        case .ready: break
        }
        return parts.joined(separator: " · ")
    }
}

/// State behind the main window. The AppController pushes recording and
/// transcription changes in; the window reads meetings from disk on refresh.
@MainActor
@Observable
final class AppState {
    let recordingsRoot: URL

    var isRecording = false
    var elapsed = "0:00"
    /// Session folder currently being recorded / transcribed.
    var recordingSession: String?
    var transcribingSession: String?

    var meetings: [Meeting] = []
    var selection: String?
    var showingSettings = false

    @ObservationIgnored var onToggleRecording: () -> Void = {}
    @ObservationIgnored var onShowLive: () -> Void = {}
    @ObservationIgnored private var documents: [String: TranscriptDocument] = [:]

    init(recordingsRoot: URL) {
        self.recordingsRoot = recordingsRoot
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selection }
    }

    /// Meetings grouped by calendar day, newest first.
    var days: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: meetings) { m in
            m.started.map { calendar.startOfDay(for: $0) } ?? .distantPast
        }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if day == .distantPast { title = "Unknown date" }
            else if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(date: .abbreviated, time: .omitted) }
            let items = groups[day, default: []].sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
            return (title, items)
        }
    }

    /// Rescan the recordings folder.
    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        let iso = ISO8601DateFormatter()
        var found: [Meeting] = []
        for dir in dirs {
            let id = dir.lastPathComponent
            let metaURL = dir.appendingPathComponent("meta.json")
            let meta = (try? Data(contentsOf: metaURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // A folder without meta.json is only a meeting while it records.
            guard meta != nil || id == recordingSession else { continue }

            let started = (meta?["started"] as? String).flatMap(iso.date(from:))
                ?? (id == recordingSession ? Date() : nil)
            found.append(Meeting(
                id: id,
                dir: dir,
                started: started,
                durationSeconds: meta?["duration_seconds"] as? Int,
                status: status(of: dir, id: id)
            ))
        }
        meetings = found
        if selection == nil || !meetings.contains(where: { $0.id == selection }) {
            selection = days.first?.meetings.first?.id
        }
        // Transcripts may have been redone since they were cached.
        documents = documents.filter { id, _ in meetings.first { $0.id == id }?.status == .ready }
    }

    private func status(of dir: URL, id: String) -> Meeting.Status {
        if id == recordingSession { return .recording }
        if id == transcribingSession { return .transcribing }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) else {
            return .waiting
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("exports.json")),
           String(decoding: data, as: UTF8.self).contains("\"failed\"") {
            return .exportFailed
        }
        return .ready
    }

    /// The transcript for a meeting, loaded once. Nil if it isn't readable
    /// as the current schema.
    func document(for meeting: Meeting) -> TranscriptDocument? {
        if let cached = documents[meeting.id] { return cached }
        guard let data = try? Data(contentsOf: meeting.dir.appendingPathComponent("transcript.json")),
              let doc = try? TranscriptDocument.decode(from: data)
        else { return nil }
        documents[meeting.id] = doc
        return doc
    }

    /// Inject meetings and transcripts directly (UI snapshots).
    func load(meetings: [Meeting], documents: [String: TranscriptDocument]) {
        self.meetings = meetings
        self.documents = documents
        selection = meetings.first?.id
    }
}
