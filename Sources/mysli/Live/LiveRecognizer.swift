import AVFoundation
import FluidAudio
import Foundation

enum LiveEvent: Sendable {
    /// The utterance in progress, as recognized so far.
    case partial(String)
    /// A finished utterance and when it started.
    case finished(String, startedAt: Date)
}

/// Streams one track through Parakeet EOU 120M, a small English streaming
/// model with end-of-utterance detection. It is less accurate than the
/// batch model, so the live view is a draft: the saved transcript is still
/// produced from the recorded files after the meeting.
actor LiveRecognizer {
    private let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1_000)

    /// Load the streaming model, downloading it on first use.
    func prepare() async throws {
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
    }

    /// Consume samples until the stream ends, emitting partial and final
    /// utterances. After each end of utterance the model state is reset, so
    /// its running transcript only ever holds the current utterance.
    func run(_ samples: AsyncStream<[Float]>, emit: @escaping @Sendable (LiveEvent) async -> Void) async {
        var lastPartial = ""
        var utteranceStart: Date?
        var reportedError = false

        for await chunk in samples {
            guard let buffer = Self.makeBuffer(chunk) else { continue }
            do {
                _ = try await manager.process(audioBuffer: buffer)
            } catch {
                if !reportedError {
                    reportedError = true
                    FileHandle.standardError.write(Data("live transcription error: \(error)\n".utf8))
                }
                continue
            }

            let text = await manager.getPartialTranscript()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if await manager.eouDetected {
                if !text.isEmpty {
                    await emit(.finished(text, startedAt: utteranceStart ?? Date()))
                }
                await manager.reset()
                lastPartial = ""
                utteranceStart = nil
            } else if text != lastPartial {
                if utteranceStart == nil, !text.isEmpty { utteranceStart = Date() }
                lastPartial = text
                await emit(.partial(text))
            }
        }

        // Recording stopped: whatever was mid-utterance becomes final.
        if let tail = try? await manager.finish() {
            let text = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                await emit(.finished(text, startedAt: utteranceStart ?? Date()))
            }
        }
        await emit(.partial(""))
        await manager.cleanup()
    }

    /// A fresh buffer per chunk, handed off to the model's actor.
    private static func makeBuffer(_ samples: [Float]) -> sending AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
