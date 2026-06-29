import Foundation

/// **First-letter signature (FL)** extraction + matching for fast
/// within-shabad pangti lookup. Brief #9.7-iOS (2026-06-29).
///
/// The idea: a sung pangti's first-letter signature ("ਸ ਪ ਭ" for
/// "ਸਤਿਗੁਰੁ ਪੂਰਾ ਭੇਟਿਆ") survives ASR mishearing of sung input much
/// better than the full transcript. The IndicConformer model mangles
/// sung syllables but typically preserves the first phoneme of each
/// word. Match the partial transcript's FL signature against the
/// pre-computed FL signatures of every pangti in the currently-
/// locked shabad — if exactly one matches, jump the highlight there
/// immediately, without waiting for the server's full-fuzzy match
/// round-trip.
///
/// **Scope.** Pure value-type utility. No state, no I/O. Used by
/// ``StreamingRaagiModeEngine`` for LOCKED-state pangti highlight
/// speedup ONLY. Never used for cross-shabad swap detection — that
/// stays server-driven through the #9.6 challenger logic.
///
/// **Script handling.** Auto-detects per word: a Gurmukhi base
/// letter at the start of a word yields a Gurmukhi FL; otherwise we
/// fall through to Latin (first ASCII letter, with the
/// `sh`/`ch`/`chh` digraph normalization the brief specified). This
/// makes the utility robust to either format the server might emit
/// without the caller having to know.
public enum FirstLetterSignature {

    // MARK: - Public API

    /// Extract a first-letter signature: one short String per
    /// whitespace-delimited word, in order. Whitespace-only / empty
    /// input returns an empty array; words yielding no recognisable
    /// first letter (pure punctuation, digits) are filtered out.
    public static func extract(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { firstLetterOf(word: String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Prefix match: returns `true` iff `query` is a prefix of
    /// `target`, element-wise. The brief allows the ASR to drop
    /// trailing words (query shorter than target), so we require
    /// `target.count >= query.count` and equality on the first
    /// `query.count` entries.
    public static func prefixMatch(query: [String], target: [String]) -> Bool {
        if query.isEmpty { return false }
        if target.count < query.count { return false }
        for i in 0..<query.count {
            if query[i] != target[i] { return false }
        }
        return true
    }

    /// Indices of every corpus entry whose FL signature has `query`
    /// as a prefix. Caller decides what counts as "unique" /
    /// "ambiguous" / "no match" based on the count of returned
    /// indices.
    public static func findCandidates(query: [String], corpus: [[String]]) -> [Int] {
        if query.isEmpty { return [] }
        var hits: [Int] = []
        hits.reserveCapacity(4)
        for (i, sig) in corpus.enumerated() {
            if prefixMatch(query: query, target: sig) {
                hits.append(i)
            }
        }
        return hits
    }

    // MARK: - Per-word extraction

    /// First-letter for a single word. Detects script per-word so
    /// mixed content (rare but possible) still produces sensible FL.
    /// Returns empty string when the word has no recognisable
    /// first letter (e.g. "॥1॥", "...", "  ").
    static func firstLetterOf(word: String) -> String {
        // Try Gurmukhi base letter first — skip leading punctuation,
        // numerals, anusvara, bindi, etc. until we find a real
        // consonant/vowel.
        for scalar in word.unicodeScalars {
            if isGurmukhiBaseLetter(scalar) {
                let ch = Character(scalar)
                if let mapped = gurmukhiNuktaMap[ch] {
                    return String(mapped)
                }
                return String(ch)
            }
        }
        // No Gurmukhi base letter found — fall through to Latin.
        return latinFirstLetter(word: word)
    }

    /// Latin first-letter with digraph collapse per Brief #9.7:
    ///   "sh*"  → "s"   ("Sharanai" → "s")
    ///   "chh*" → "c"   ("Chhota"   → "c")
    ///   "ch*"  → "c"   ("Chand"    → "c")
    /// All other words return their first ASCII letter, lowercased.
    /// The digraph normalisation is mostly a no-op for first-letter
    /// purposes (the bare letter already matches) but explicit for
    /// future-proofing and matching the brief's contract exactly.
    static func latinFirstLetter(word: String) -> String {
        let lower = word.lowercased()
        if lower.hasPrefix("chh") { return "c" }
        if lower.hasPrefix("ch")  { return "c" }
        if lower.hasPrefix("sh")  { return "s" }
        for ch in lower {
            if ch.isASCII && ch.isLetter {
                return String(ch)
            }
        }
        return ""
    }

    // MARK: - Gurmukhi script detection + nukta normalisation

    /// Nukta-variant collapsing for FL matching purposes. The
    /// precomposed nukta forms have separate Unicode identity but
    /// share the SAME first-letter for FL signatures — a corpus
    /// pangti starting with ਸ should match an ASR word starting with
    /// either ਸ or ਸ਼.
    ///
    /// Source: Unicode Gurmukhi block (U+0A00–U+0A7F).
    private static let gurmukhiNuktaMap: [Character: Character] = [
        "\u{0A33}": "\u{0A32}",  // ਲ਼ (LLA)    → ਲ  (LA)
        "\u{0A36}": "\u{0A38}",  // ਸ਼ (SHA)   → ਸ  (SA)
        "\u{0A59}": "\u{0A16}",  // ਖ਼ (KHHA)  → ਖ  (KHA)
        "\u{0A5A}": "\u{0A17}",  // ਗ਼ (GHHA)  → ਗ  (GA)
        "\u{0A5B}": "\u{0A1C}",  // ਜ਼ (ZA)    → ਜ  (JA)
        "\u{0A5E}": "\u{0A2B}",  // ਫ਼ (FA)    → ਫ  (PHA)
    ]

    /// Is this scalar a Gurmukhi base consonant/independent vowel
    /// that can sit at the start of a word? Excludes combining
    /// marks (nukta, vowel signs, halant, anusvara), digits, and
    /// punctuation. ੜ (U+0A5C, RRA) is included since it's a
    /// legitimate word-initial consonant in modern Punjabi spellings
    /// (though rare).
    static func isGurmukhiBaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A05...0x0A14: return true   // Independent vowels  ਅ – ਔ
        case 0x0A15...0x0A28: return true   // Consonants          ਕ – ਨ
        case 0x0A2A...0x0A30: return true   // Consonants          ਪ – ਰ
        case 0x0A32, 0x0A33:  return true   // ਲ, ਲ਼
        case 0x0A35, 0x0A36:  return true   // ਵ, ਸ਼
        case 0x0A38, 0x0A39:  return true   // ਸ, ਹ
        case 0x0A59...0x0A5E: return true   // Additional consonants
        case 0x0A72...0x0A74: return true   // Iri (ੲ), Ura (ੳ), Ek Onkar (ੴ)
        default:              return false
        }
    }
}
