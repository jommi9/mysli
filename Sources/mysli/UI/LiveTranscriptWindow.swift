import AppKit

/// Floating panel showing the live transcript. Non-activating, so opening it
/// never pulls focus from the call, and excluded from screen capture, so it
/// stays off screen shares and recordings of your screen.
@MainActor
final class LiveTranscriptWindow {
    private var panel: NSPanel?
    private var scrollView: NSScrollView?
    private var textView: NSTextView?
    private var transcript: LiveTranscript?

    /// Point the window at a new recording's transcript.
    func attach(_ transcript: LiveTranscript) {
        self.transcript?.onChange = nil
        self.transcript = transcript
        transcript.onChange = { [weak self] in self?.render() }
        render()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        render()
        panel.orderFrontRegardless()
    }

    // MARK: -

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live transcript"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("mysli.live-transcript")
        if !panel.setFrameUsingName("mysli.live-transcript") {
            panel.center()
        }

        let scrollView = NSTextView.scrollableTextView()
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = panel.contentView?.bounds ?? .zero
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 8, height: 10)
            self.textView = textView
        }
        panel.contentView?.addSubview(scrollView)

        self.panel = panel
        self.scrollView = scrollView
        return panel
    }

    private func render() {
        guard let textView, let scrollView, let storage = textView.textStorage else { return }

        let wasAtBottom = scrollView.documentVisibleRect.maxY >= textView.bounds.maxY - 40
        storage.setAttributedString(Self.attributed(transcript))
        if wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private static let body = NSFont.systemFont(ofSize: 13)
    private static let bold = NSFont.boldSystemFont(ofSize: 13)
    private static let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    private static func color(_ speaker: LiveTranscript.Speaker) -> NSColor {
        speaker == .me ? .systemBlue : .systemOrange
    }

    private static func attributed(_ transcript: LiveTranscript?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }

        guard let transcript else {
            add("No recording yet.", body, .secondaryLabelColor)
            return out
        }
        if let status = transcript.status {
            add(status + "\n\n", body, .secondaryLabelColor)
        }
        for line in transcript.lines {
            add("\(transcript.timestamp(line.startedAt))  ", mono, .tertiaryLabelColor)
            add("\(line.speaker.label): ", bold, color(line.speaker))
            add(line.text + "\n", body, .labelColor)
        }

        let partials: [(LiveTranscript.Speaker, String?)] = [
            (.them, transcript.partials[.them]),
            (.me, transcript.visibleMicPartial),
        ]
        for case let (speaker, text?) in partials where !text.isEmpty {
            add("\(speaker.label): ", bold, color(speaker).withAlphaComponent(0.6))
            add(text + "…\n", body, .secondaryLabelColor)
        }

        if out.length == 0 {
            add("Listening…", body, .secondaryLabelColor)
        }
        return out
    }
}
