import Foundation

/// Glue between FluidAudio's vocabulary rescorer and timed words.
///
/// The rescorer reports its corrections as (original phrase, replacement)
/// pairs plus a flat string, which loses word timings. These helpers map the
/// corrections back onto `TimedWord`s, and split a long track into windows so
/// the rescorer's CTC pass never has to hold a whole meeting in memory.
public enum VocabularyAlignment {
    public struct Replacement: Sendable, Equatable {
        /// The words as the ASR produced them, space-joined.
        public let original: String
        /// The vocabulary term that replaces them.
        public let replacement: String

        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }

    /// Apply each replacement to the first not-yet-replaced span of `words`
    /// whose normalized text equals the replacement's original phrase. The
    /// span collapses into one word timed from its first start to its last
    /// end. Trailing sentence punctuation on the span is kept so segmenting
    /// still breaks where it did.
    public static func apply(_ replacements: [Replacement], to words: [TimedWord]) -> [TimedWord] {
        guard !replacements.isEmpty, !words.isEmpty else { return words }
        let normalized = words.map { WordNormalizer.normalize($0.text) }
        var replacedBy: [Int: (length: Int, text: String)] = [:]
        var consumed = Set<Int>()

        for r in replacements {
            let target = WordNormalizer.words(in: r.original)
            guard !target.isEmpty, target.count <= words.count else { continue }
            var start = 0
            while start + target.count <= words.count {
                let span = start..<(start + target.count)
                if span.allSatisfy({ !consumed.contains($0) }),
                   Array(normalized[span]) == target
                {
                    replacedBy[start] = (target.count, r.replacement)
                    consumed.formUnion(span)
                    break
                }
                start += 1
            }
        }

        var out: [TimedWord] = []
        var i = 0
        while i < words.count {
            guard let hit = replacedBy[i] else {
                out.append(words[i])
                i += 1
                continue
            }
            let (length, text) = hit
            let last = words[i + length - 1]
            var merged = text
            if let p = last.text.last, ".?!,".contains(p), merged.last != p {
                merged.append(p)
            }
            out.append(TimedWord(text: merged, start: words[i].start, end: last.end))
            i += length
        }
        return out
    }

    /// A contiguous slice of tokens to rescore together.
    public struct Window: Sendable, Equatable {
        /// Token indices in the window.
        public let tokens: Range<Int>
        /// Audio span to feed the CTC spotter, padded around the tokens.
        public let audioStart: TimeInterval
        public let audioEnd: TimeInterval
    }

    /// Split a token stream into windows of roughly `target` seconds. A window
    /// only ends where the next token starts a new word and there is a pause
    /// of at least `minGap`, or, failing that, once it reaches `maxLength`.
    ///
    /// - Parameters:
    ///   - starts/ends: token start and end times, sorted.
    ///   - startsWord: whether each token begins a new word.
    ///   - duration: total audio length, to clamp padding.
    public static func windows(
        starts: [TimeInterval],
        ends: [TimeInterval],
        startsWord: [Bool],
        duration: TimeInterval,
        target: TimeInterval = 90,
        maxLength: TimeInterval = 150,
        minGap: TimeInterval = 0.4,
        padding: TimeInterval = 1.0
    ) -> [Window] {
        let n = min(starts.count, ends.count, startsWord.count)
        guard n > 0 else { return [] }
        var out: [Window] = []
        var first = 0

        func close(at end: Int) {
            out.append(Window(
                tokens: first..<end,
                audioStart: max(0, starts[first] - padding),
                audioEnd: min(duration, ends[end - 1] + padding)
            ))
            first = end
        }

        for i in 1..<n {
            guard startsWord[i] else { continue }
            let length = ends[i - 1] - starts[first]
            let pause = starts[i] - ends[i - 1]
            if (length >= target && pause >= minGap) || length >= maxLength {
                close(at: i)
            }
        }
        close(at: n)
        return out
    }
}
