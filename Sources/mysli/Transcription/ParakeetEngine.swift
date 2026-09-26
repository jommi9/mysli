import AVFoundation
import FluidAudio
import Foundation
import MysliCore

/// Parakeet TDT 0.6B via FluidAudio's Core ML port. v2 is English-only and
/// the default (best English recall); v3 covers 25 European languages,
/// Finnish included, and detects the language itself. Models download once
/// into FluidAudio's managed cache (~600 MB); after that, transcription runs
/// entirely on-device at roughly 20 seconds per hour of audio on Apple
/// Silicon.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model: String

    private let version: AsrModelVersion
    private let vocabularyURL: URL?
    private var manager: AsrManager?
    private var booster: VocabularyBooster?

    init(version: AsrModelVersion, vocabularyURL: URL?) {
        self.version = version
        self.vocabularyURL = vocabularyURL
        self.model = version == .v3
            ? "parakeet-tdt-0.6b-v3-coreml"
            : "parakeet-tdt-0.6b-v2-coreml"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager

        // A broken vocabulary file or a failed CTC model download costs the
        // boost, never the transcript.
        if let vocabularyURL {
            do {
                booster = try await VocabularyBooster.load(from: vocabularyURL)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: vocabulary boosting disabled — \(vocabularyURL.path): \(error)\n".utf8
                ))
            }
        }
    }

    func transcribe(_ audio: URL) async throws -> [TimedWord] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        let tokens = result.tokenTimings ?? []

        var words: [TimedWord]
        if let booster, !tokens.isEmpty {
            do {
                words = try await booster.rescore(tokens: tokens, audio: audio)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: vocabulary boosting failed for \(audio.lastPathComponent): \(error)\n".utf8
                ))
                words = Self.words(from: tokens)
            }
        } else {
            words = Self.words(from: tokens)
        }

        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TimedWord(text: text, start: 0, end: result.duration)]
        }
        return words
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
        booster = nil
    }

    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        buildWordTimings(from: tokens).map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
    }
}
