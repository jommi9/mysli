import Foundation

/// Groups word timings into readable segments: break on sentence-ending
/// punctuation (Parakeet emits punctuation), a silence gap, or a hard length
/// cap so a run-on speaker still wraps.
public enum Segmenter {
    public static func segments(
        from words: [TimedWord],
        maxGap: TimeInterval = 1.0,
        maxWords: Int = 60
    ) -> [TimedSegment] {
        var out: [TimedSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TimedSegment(
                start: first.start,
                end: last.end,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.start - last.end > maxGap {
                flush()
            }
            current.append(word)
            let endsSentence = word.text.hasSuffix(".")
                || word.text.hasSuffix("?")
                || word.text.hasSuffix("!")
            if endsSentence || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return out
    }
}
