import Foundation

/// Live transcription for one recording: a feed per track that the recorders
/// push into, and one streaming recognizer per feed. Nothing here can fail a
/// recording; if the model can't load, the live view says so and the
/// recording carries on.
final class LiveSession: Sendable {
    let mic: LiveTrackFeed
    let system: LiveTrackFeed
    private let transcript: LiveTranscript
    private let task: Task<Void, Never>

    @MainActor
    init(transcript: LiveTranscript) {
        let mic = LiveTrackFeed()
        let system = LiveTrackFeed()
        self.mic = mic
        self.system = system
        self.transcript = transcript
        let micSamples = mic.samples
        let systemSamples = system.samples
        task = Task {
            let micRecognizer = LiveRecognizer()
            let systemRecognizer = LiveRecognizer()
            transcript.setStatus("loading live model…")
            do {
                // One after the other: both share the same model cache and
                // would otherwise race to download it on first use.
                try await micRecognizer.prepare()
                try await systemRecognizer.prepare()
            } catch {
                FileHandle.standardError.write(Data("live transcription unavailable: \(error)\n".utf8))
                transcript.setStatus("live transcript unavailable — recording continues")
                return
            }
            transcript.setStatus(nil)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await micRecognizer.run(micSamples) { event in
                        await transcript.handle(.me, event)
                    }
                }
                group.addTask {
                    await systemRecognizer.run(systemSamples) { event in
                        await transcript.handle(.them, event)
                    }
                }
            }
        }
    }

    /// Call after the recorders have stopped. Returns once both recognizers
    /// have flushed their last utterance.
    func finish() async {
        mic.finish()
        system.finish()
        await task.value
        await transcript.setStatus("recording stopped · final transcript follows in the session folder")
    }
}
