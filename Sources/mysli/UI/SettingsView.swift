import SwiftUI
import UniformTypeIdentifiers

/// The handful of settings worth a UI. Everything else stays in
/// config.json; saving rewrites only these keys.
@MainActor
@Observable
final class SettingsModel {
    var model = "v2"
    var echoFilter = true
    var liveEnabled = true
    var liveShowWindow = true
    var calendarEnabled = true
    var exportFolders: [URL] = []
    var notionDatabaseID = ""
    var hasNotionToken = false

    static func fromConfig() -> SettingsModel {
        let m = SettingsModel()
        m.model = Config.parakeetVersion() == .v3 ? "v3" : "v2"
        m.echoFilter = Config.echoFilterEnabled()
        m.liveEnabled = Config.liveEnabled()
        m.liveShowWindow = Config.liveShowWindow()
        m.calendarEnabled = Config.calendarEnabled()
        m.exportFolders = Config.exportFolders()
        m.notionDatabaseID = Config.notionDatabaseID() ?? ""
        m.hasNotionToken = Secrets.notionToken() != nil
        return m
    }

    func save() throws {
        let folders = exportFolders.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        let notionID = notionDatabaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        try Config.update { json in
            var transcription = json["transcription"] as? [String: Any] ?? [:]
            transcription["model"] = model
            transcription["echo_filter"] = echoFilter
            json["transcription"] = transcription

            var live = json["live"] as? [String: Any] ?? [:]
            live["enabled"] = liveEnabled
            live["show_window"] = liveShowWindow
            json["live"] = live

            var calendar = json["calendar"] as? [String: Any] ?? [:]
            calendar["enabled"] = calendarEnabled
            json["calendar"] = calendar

            var exports = json["exports"] as? [String: Any] ?? [:]
            exports["folders"] = folders
            if notionID.isEmpty {
                exports["notion"] = nil
            } else {
                var notion = exports["notion"] as? [String: Any] ?? [:]
                notion["database_id"] = notionID
                exports["notion"] = notion
            }
            json["exports"] = exports
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let recordingsRoot: URL
    let dismiss: () -> Void

    @State private var choosingFolder = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Transcription") {
                    Picker("Language", selection: $model.model) {
                        Text("English (most accurate)").tag("v2")
                        Text("Multilingual, incl. Finnish").tag("v3")
                    }
                    Toggle("Remove echo when on speakers", isOn: $model.echoFilter)
                    Toggle("Name meetings and people from Calendar", isOn: $model.calendarEnabled)
                }

                Section("Live transcript") {
                    Toggle("Transcribe live while recording", isOn: $model.liveEnabled)
                    Toggle("Open the live window when recording starts", isOn: $model.liveShowWindow)
                        .disabled(!model.liveEnabled)
                }

                Section {
                    LabeledContent("Recordings") {
                        Text((recordingsRoot.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.exportFolders, id: \.self) { folder in
                        LabeledContent("Copy to") {
                            HStack {
                                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.exportFolders.removeAll { $0 == folder }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button("Add export folder…") { choosingFolder = true }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Transcripts are copied as Markdown and JSON. Pick a Google Drive, Dropbox or iCloud folder to sync them.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Database ID", text: $model.notionDatabaseID, prompt: Text("Leave empty to skip Notion"))
                    LabeledContent("Token") {
                        Text(model.hasNotionToken ? "In Keychain" : "Missing")
                            .foregroundStyle(model.hasNotionToken ? Color.secondary : Color.orange)
                    }
                } header: {
                    Text("Notion")
                } footer: {
                    if !model.hasNotionToken {
                        Text("Add the integration token with: security add-generic-password -s mysli.notion -a notion -w")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.save()
                        dismiss()
                    } catch {
                        self.error = "Couldn't save: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 720)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result, !model.exportFolders.contains(url) {
                model.exportFolders.append(url)
            }
        }
    }
}
