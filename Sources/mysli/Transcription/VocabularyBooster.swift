import FluidAudio
import Foundation
import MysliCore

/// Custom-vocabulary boosting for Parakeet, using FluidAudio's CTC keyword
/// spotter. Parakeet takes no text prompt, so names it has never seen
/// ("Hyperliquid", "EigenLayer") come out as near-miss English. A small CTC
/// model (~100 MB, downloaded on first use) scores each vocabulary term
/// against the audio, and a term replaces the ASR's words only when the audio
/// supports it better than what the ASR wrote.
///
/// The vocabulary file is FluidAudio's format: one term per line, optionally
/// `Term: alias one, alias two` for known mishearings; `#` starts a comment.
struct VocabularyBooster: Sendable {
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let minSimilarity: Float
    let cbw: Float

    /// Nil when the file has no usable terms.
    static func load(from url: URL) async throws -> VocabularyBooster? {
        let (vocabulary, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: url.path)
        guard !vocabulary.terms.isEmpty else { return nil }

        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocabulary,
            config: .default,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        )
        let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
        FileHandle.standardError.write(Data(
            "vocabulary: \(vocabulary.terms.count) term(s) from \(url.path)\n".utf8
        ))
        return VocabularyBooster(
            vocabulary: vocabulary,
            spotter: spotter,
            rescorer: rescorer,
            minSimilarity: tuning.minSimilarity,
            cbw: tuning.cbw
        )
    }

    /// Rescore one track's tokens and return corrected, timed words.
    ///
    /// Works in windows of about 90 seconds: the CTC log-probability matrix
    /// for a whole hour would run to several hundred MB, and corrections are
    /// local anyway.
    func rescore(tokens: [TokenTiming], audio: URL) async throws -> [TimedWord] {
        let sampleRate = 16_000.0
        let samples = try AudioConverter().resampleAudioFile(audio)
        let windows = VocabularyAlignment.windows(
            starts: tokens.map(\.startTime),
            ends: tokens.map(\.endTime),
            startsWord: tokens.map { $0.token.hasPrefix("▁") || $0.token.hasPrefix(" ") },
            duration: Double(samples.count) / sampleRate
        )

        var out: [TimedWord] = []
        var applied = 0
        for window in windows {
            let slice = Array(tokens[window.tokens])
            let words = ParakeetEngine.words(from: slice)
            let from = max(0, Int(window.audioStart * sampleRate))
            let to = min(samples.count, Int(window.audioEnd * sampleRate))
            guard to > from else {
                out += words
                continue
            }

            // The spotter sees only this window's audio, so token times move
            // onto the window's clock.
            let local = slice.map {
                TokenTiming(
                    token: $0.token,
                    tokenId: $0.tokenId,
                    startTime: $0.startTime - window.audioStart,
                    endTime: $0.endTime - window.audioStart,
                    confidence: $0.confidence
                )
            }
            let spot = try await spotter.spotKeywordsWithLogProbs(
                audioSamples: Array(samples[from..<to]),
                customVocabulary: vocabulary,
                minScore: nil
            )
            guard !spot.logProbs.isEmpty else {
                out += words
                continue
            }

            let output = rescorer.ctcTokenRescore(
                transcript: words.map(\.text).joined(separator: " "),
                tokenTimings: local,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: cbw,
                minSimilarity: minSimilarity
            )
            let replacements = output.replacements.compactMap { r -> VocabularyAlignment.Replacement? in
                guard r.shouldReplace, let replacement = r.replacementWord else { return nil }
                return .init(original: r.originalWord, replacement: replacement)
            }
            applied += replacements.count
            out += VocabularyAlignment.apply(replacements, to: words)
        }

        if applied > 0 {
            FileHandle.standardError.write(Data(
                "vocabulary: \(applied) correction(s) in \(audio.lastPathComponent)\n".utf8
            ))
        }
        return out
    }
}
