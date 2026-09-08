import Foundation

public final class TokenEstimator: Sendable {
    public static let shared = TokenEstimator()

    private let accurateCounter: (@Sendable (String) -> Int)?

    public init(accurateCounter: (@Sendable (String) -> Int)? = nil) {
        self.accurateCounter = accurateCounter
    }

    public func estimate(_ text: String) -> Int {
        if let accurateCounter = accurateCounter {
            return accurateCounter(text)
        }
        if text.isEmpty { return 0 }

        // Conservative Unicode-aware fallback when a model tokenizer is unavailable.
        // Latin runs ~4 chars/token; CJK and other letters count as one token each
        // (o200k is typically ~1.5 CJK chars/token — over-counting is safer than
        // the previous ASCII-only regex, which scored 2400 Han characters as 1).
        var tokens = 0
        var latinRun = 0
        var whitespaceRun = false

        func flushLatin() {
            guard latinRun > 0 else { return }
            tokens += 1 + (latinRun / 4)
            latinRun = 0
        }

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                flushLatin()
                whitespaceRun = false
                tokens += 1
                continue
            }
            if CharacterSet.whitespaces.contains(scalar) {
                flushLatin()
                if !whitespaceRun {
                    tokens += 1
                    whitespaceRun = true
                }
                continue
            }
            whitespaceRun = false

            if isLatinAlphanumeric(scalar) {
                latinRun += 1
                continue
            }
            flushLatin()
            if scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar) {
                // Non-Latin letters and digits: one token per scalar.
                tokens += 1
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            {
                tokens += 1
            }
        }
        flushLatin()
        return max(1, tokens)
    }

    private func isLatinAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }
}
