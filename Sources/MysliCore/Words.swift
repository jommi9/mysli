import Foundation

/// One recognized word on a track's clock (seconds from the track start, or
/// from the session start once the track offset has been applied).
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// The word shifted onto another clock.
    public func shifted(by offset: TimeInterval) -> TimedWord {
        TimedWord(text: text, start: start + offset, end: end + offset)
    }
}

/// A readable run of words from one track.
public struct TimedSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// The words the segment was built from, with their own timings.
    public var words: [TimedWord]

    public init(start: TimeInterval, end: TimeInterval, text: String, words: [TimedWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public enum WordNormalizer {
    /// Lowercased letters and digits only, so "Yeah," and "yeah" compare
    /// equal. Returns "" for tokens that are pure punctuation.
    public static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    /// Normalized, non-empty words of a free-text string.
    public static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }
}
