import Foundation

/// Removes speaker bleed from the mic track.
///
/// Without headphones, the mic hears the other side of the call through the
/// speakers, so their words get transcribed twice: once cleanly from the
/// system track and once, attributed to "me", from the mic. The system track
/// is the clean far-end reference and both tracks share one clock, so an echo
/// shows up as mic words that repeat system words at almost the same moment.
///
/// Matching is word-level: a mic word matches when the same normalized word
/// starts on the system track within a small window around it. Only runs of
/// matches are removed, so a lone "yeah" that happens to coincide with theirs
/// survives, and your own words spoken over them (double-talk) stay.
public struct EchoFilter: Sendable {
    /// How far a mic word may start *before* its system counterpart. Covers
    /// word-timing jitter between two independent ASR passes.
    public var leadTolerance: TimeInterval
    /// How far a mic word may start *after* its system counterpart. Covers
    /// output latency, the acoustic path and timing jitter.
    public var lagTolerance: TimeInterval
    /// Matched words a run needs before it is treated as echo.
    public var minRunMatches: Int
    /// A gap longer than this between mic words ends a run (and an utterance).
    public var maxWordGap: TimeInterval

    public init(
        leadTolerance: TimeInterval = 0.5,
        lagTolerance: TimeInterval = 1.5,
        minRunMatches: Int = 3,
        maxWordGap: TimeInterval = 1.0
    ) {
        self.leadTolerance = leadTolerance
        self.lagTolerance = lagTolerance
        self.minRunMatches = minRunMatches
        self.maxWordGap = maxWordGap
    }

    public struct Result: Sendable, Equatable {
        public let kept: [TimedWord]
        public let removed: [TimedWord]
    }

    /// Split `mic` into words to keep and words judged to be echo of
    /// `system`. Both arrays must be on the same clock and sorted by start.
    public func removeEcho(mic: [TimedWord], system: [TimedWord]) -> Result {
        guard !mic.isEmpty, !system.isEmpty else {
            return Result(kept: mic, removed: [])
        }

        // Start times of each system word, keyed by normalized text.
        var systemStarts: [String: [TimeInterval]] = [:]
        for word in system {
            let key = WordNormalizer.normalize(word.text)
            guard !key.isEmpty else { continue }
            systemStarts[key, default: []].append(word.start)
        }
        for key in systemStarts.keys {
            systemStarts[key]?.sort()
        }

        // matched: the word may be part of an echo run.
        // counts: it is real evidence (punctuation-only tokens ride along
        // without counting toward the run threshold).
        var matched = [Bool](repeating: false, count: mic.count)
        var counts = [Bool](repeating: false, count: mic.count)
        for (i, word) in mic.enumerated() {
            let key = WordNormalizer.normalize(word.text)
            if key.isEmpty {
                matched[i] = true
                continue
            }
            guard let starts = systemStarts[key] else { continue }
            let low = word.start - lagTolerance
            let high = word.start + leadTolerance
            let idx = Self.lowerBound(starts, low)
            if idx < starts.count, starts[idx] <= high {
                matched[i] = true
                counts[i] = true
            }
        }

        func gapBefore(_ i: Int) -> TimeInterval {
            i == 0 ? .infinity : mic[i].start - mic[i - 1].end
        }

        var remove = [Bool](repeating: false, count: mic.count)
        var i = 0
        while i < mic.count {
            guard counts[i] else {
                i += 1
                continue
            }
            var k = i
            var lastMatched = i
            var matches = 0
            while k < mic.count {
                if k > i, gapBefore(k) > maxWordGap { break }
                if matched[k] {
                    if counts[k] { matches += 1 }
                    lastMatched = k
                    k += 1
                    continue
                }
                // One garbled word between two matches is still echo (the
                // mic hears the far end degraded, so its ASR drifts).
                if k + 1 < mic.count, matched[k + 1], gapBefore(k + 1) <= maxWordGap {
                    k += 1
                    continue
                }
                break
            }

            let wholeUtterance = gapBefore(i) > maxWordGap
                && (lastMatched == mic.count - 1 || gapBefore(lastMatched + 1) > maxWordGap)
            let hasBridge = (i...lastMatched).contains { !matched[$0] }
            if matches >= minRunMatches || (wholeUtterance && !hasBridge && matches >= 2) {
                for j in i...lastMatched { remove[j] = true }
            }
            i = lastMatched + 1
        }

        var kept: [TimedWord] = []
        var removed: [TimedWord] = []
        for (j, word) in mic.enumerated() {
            if remove[j] { removed.append(word) } else { kept.append(word) }
        }
        return Result(kept: kept, removed: removed)
    }

    /// Whether a finished live line from the mic is mostly a repeat of a
    /// line from the other track. Used for the live view, where there are no
    /// word timings, only utterances.
    public func isEcho(line: String, of other: String, minFraction: Double = 0.7) -> Bool {
        let words = WordNormalizer.words(in: line)
        guard words.count >= 2 else { return false }
        var pool: [String: Int] = [:]
        for w in WordNormalizer.words(in: other) { pool[w, default: 0] += 1 }
        var hits = 0
        for w in words {
            if let n = pool[w], n > 0 {
                pool[w] = n - 1
                hits += 1
            }
        }
        return Double(hits) / Double(words.count) >= minFraction
    }

    /// First index whose value is >= `value`.
    private static func lowerBound(_ sorted: [TimeInterval], _ value: TimeInterval) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
