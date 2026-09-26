import AppKit
import MysliCore
import SwiftUI

/// The main window: meetings on the left, the selected transcript on the
/// right, the record button on top of the list.
struct MainView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar(state: state)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            if let meeting = state.selectedMeeting {
                MeetingDetail(meeting: meeting, state: state)
                    .id(meeting.id)
            } else {
                EmptyDetail()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $state.showingSettings) {
            SettingsView(model: SettingsModel.fromConfig(), recordingsRoot: state.recordingsRoot) {
                state.showingSettings = false
            }
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            RecordButton(state: state)
                .padding(12)
            List(selection: $state.selection) {
                ForEach(state.days, id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id as String?)
                        }
                    }
                }
            }
            .overlay {
                if state.meetings.isEmpty {
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RecordButton: View {
    let state: AppState

    var body: some View {
        Button {
            state.onToggleRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                Text(state.isRecording ? "Stop · \(state.elapsed)" : "Start recording")
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isRecording ? .red : .accentColor)
        .controlSize(.large)
        .keyboardShortcut("r", modifiers: .command)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.headline)
                if !meeting.subtitle.isEmpty {
                    Text(meeting.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusIcon
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        switch meeting.status {
        case .recording:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .transcribing:
            ProgressView().controlSize(.small)
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .exportFailed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Detail

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Press Start recording when your call begins.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingDetail: View {
    let meeting: Meeting
    let state: AppState

    var body: some View {
        let document = meeting.status == .ready || meeting.status == .exportFailed
            ? state.document(for: meeting) : nil
        VStack(alignment: .leading, spacing: 0) {
            header(document)
                .padding(20)
            Divider()
            if let document {
                TranscriptList(document: document)
            } else {
                placeholder
            }
        }
    }

    private func header(_ document: TranscriptDocument?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(document?.session.title ?? "Meeting \(meeting.title)")
                .font(.title2.weight(.semibold))
            if let started = meeting.started {
                Text(started.formatted(date: .complete, time: .shortened)
                     + (meeting.durationSeconds.map { " · \(max(1, $0 / 60)) min" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            if let document, document.speakers.contains(where: { $0.talk_seconds > 0 }) {
                TalkShareBar(speakers: document.speakers)
            }
            HStack {
                if let document {
                    Button("Copy transcript", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(document.markdown(), forType: .string)
                    }
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.dir])
                }
                if meeting.status == .exportFailed {
                    Label("Export failed, retries on next launch", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 10) {
            switch meeting.status {
            case .recording:
                Text("Recording…").font(.headline)
                Button("Show live transcript") { state.onShowLive() }
            case .transcribing:
                ProgressView()
                Text("Transcribing, usually under a minute.").foregroundStyle(.secondary)
            case .waiting:
                Text("Waiting to be transcribed.").foregroundStyle(.secondary)
            case .ready, .exportFailed:
                Text("This transcript was made by an older version.\nDelete transcript.json in its folder and restart mysli to redo it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TalkShareBar: View {
    let speakers: [TranscriptDocument.Speaker]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(speakers, id: \.id) { speaker in
                        Rectangle()
                            .fill(SpeakerStyle.color(speaker.id))
                            .frame(width: max(2, geo.size.width * speaker.talk_share))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                ForEach(speakers, id: \.id) { speaker in
                    HStack(spacing: 5) {
                        Circle().fill(SpeakerStyle.color(speaker.id)).frame(width: 7, height: 7)
                        Text("\(speaker.label) \(Int((speaker.talk_share * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct TranscriptList: View {
    let document: TranscriptDocument

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(document.segments, id: \.id) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(TranscriptDocument.clock(segment.start_ms))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(TranscriptDocument.speakerLabel(segment.speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SpeakerStyle.color(segment.speaker))
                            Text(segment.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

enum SpeakerStyle {
    static func color(_ speaker: String) -> Color {
        speaker == "me" ? .blue : .orange
    }
}
