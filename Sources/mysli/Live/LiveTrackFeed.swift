import AVFoundation
import Foundation
import os

/// Audio-thread end of a live stream: turns recorder buffers into 16 kHz
/// mono samples for the streaming model and hands them over through an
/// `AsyncStream`.
///
/// `push` runs synchronously inside the recorder callback (the system tap's
/// buffers are only valid for the duration of that call), so it converts
/// right away and never blocks. If the recognizer falls behind, for example
/// while its model downloads, the stream keeps only the newest minute of
/// audio. The live view may then skip ahead; the recording on disk and the
/// final transcript are unaffected.
final class LiveTrackFeed: @unchecked Sendable {
    let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let resampler = LiveResampler()
    private var pending: [Float] = []

    /// Yield in ~100 ms chunks rather than per callback (the system tap
    /// delivers ~10 ms buffers).
    private static let chunkSamples = 1_600
    private static let maxChunks = 600

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Float].self,
            bufferingPolicy: .bufferingNewest(Self.maxChunks)
        )
        self.samples = stream
        self.continuation = continuation
    }

    /// Called on the recorder's audio thread.
    func push(_ buffer: AVAudioPCMBuffer) {
        pending += resampler.resample(buffer)
        if pending.count >= Self.chunkSamples {
            continuation.yield(pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// End the stream after the recorder has stopped delivering buffers.
    func finish() {
        if !pending.isEmpty {
            continuation.yield(pending)
            pending.removeAll()
        }
        continuation.finish()
    }
}

/// Stateful 16 kHz mono converter. One `AVAudioConverter` lives across
/// buffers so the resampling filter carries over between them instead of
/// restarting (and clicking) at every buffer edge.
final class LiveResampler {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
            inputFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        // The converter pulls input synchronously inside convert(). Swift 6
        // rejects mutating a captured var in this block, hence the lock.
        // `.noDataNow` (rather than end of stream) keeps the converter's
        // state alive for the next buffer.
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let already = supplied.withLock { state -> Bool in
                defer { state = true }
                return state
            }
            if already {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
