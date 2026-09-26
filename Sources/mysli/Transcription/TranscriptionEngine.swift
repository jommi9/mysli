import Foundation
import MysliCore

/// A speech-to-text engine mysli can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so mysli never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    /// Timed words for one track, relative to that track's own start. Word
    /// level (rather than segments) so the coordinator can drop echo from
    /// the mic track before anything is grouped into sentences.
    func transcribe(_ audio: URL) async throws -> [TimedWord]
    func release() async
}
