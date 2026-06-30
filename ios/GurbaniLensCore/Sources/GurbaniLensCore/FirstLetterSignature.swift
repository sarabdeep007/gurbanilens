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

    /// Like ``extract``, but treats input as AnmolLipi / GurbaniAkhar
    /// ASCII-encoded Gurmukhi. For each whitespace-delimited word,
    /// looks up the first character in the canonical anvaad-js
    /// AnmolLipi → Unicode mapping (defined in `AnmolLipi.mapping`,
    /// same module), then keeps only single Gurmukhi base letters
    /// (consonants + independent vowel carriers). Words whose first
    /// char has no mapping or whose mapping yields no base letter
    /// are skipped. Output shape is identical to ``extract``
    /// (single-codepoint strings).
    ///
    /// Brief #9.11-iOS: BaniDB v4 stores AnmolLipi in `gurmukhi`; no
    /// `_unicode` column yet. ShabadCache falls back here when
    /// `gurmukhiUnicode` is nil so FL signatures live in the same
    /// Unicode plane as the ASR partials (which is what the matcher
    /// expects).
    public static func extractFromAnmolLipi(_ text: String) -> [String] {
        var out: [String] = []
        out.reserveCapacity(16)
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            guard let first = word.first else { continue }
            // Anvaad-js mapping lives on the existing internal
            // `AnmolLipi` enum (same module). Its `mapping` is the
            // canonical Khalsa Foundation port — using it directly
            // avoids a hand-rolled fork that could disagree on
            // edge cases (e.g. `a` → ੳ carrier vs ਅ vowel).
            guard let mapped = AnmolLipi.mapping[first] else { continue }
            // Some mappings produce multi-scalar outputs for
            // combining marks (e.g. H → ੍ਹ, ƒ → ਨੂੰ). For FL
            // purposes pick the FIRST Gurmukhi base scalar from the
            // mapped value. Word-initial chars almost always yield
            // a single base directly; this is defensive.
            var letter: String = ""
            for scalar in mapped.unicodeScalars {
                if isGurmukhiBaseLetter(scalar) {
                    letter = String(scalar)
                    break
                }
            }
            if !letter.isEmpty {
                out.append(letter)
            }
        }
        return out
    }

    /// Longest contiguous run of matching first-letters between query and
    /// target, allowing the match to start at ANY position in EITHER array.
    /// Returns (matchLength, queryStart, targetStart).
    ///
    /// Brief #9.10-iOS generalization of #9.9. Previous version anchored the
    /// match to target[0], so it required the pangti's FIRST letter to
    /// appear in the partial. ASR sliding-window partials scroll past the
    /// pangti's head quickly: by mid-pangti, partial FL = e.g. "ਪ ਸ ਚ" but
    /// pangti FL = "ਤ ਵ ਨ ਲ ਪ ਸ" — the head "ਤ ਵ" is gone and the old
    /// algorithm returned 0. True longest-common-substring (any qStart,
    /// any tStart) now matches "ਪ ਸ" inside the pangti's middle.
    ///
    /// Examples:
    ///   query=[ਪ,ਸ,ਚ], target=[ਤ,ਵ,ਨ,ਲ,ਪ,ਸ] → (2, 0, 4)
    ///   query=[ਚ,ਹ,ਰ,ਕ,ਦ], target=[ਚ,ਹ,ਰ,ਕ] → (4, 0, 0)
    ///   query=[ਬ,ਪ,ਸ,ਚ], target=[ਪ,ਸ,ਚ,ਹ] → (3, 1, 0)
    public static func longestSubstringMatch(query: [String], target: [String]) -> (length: Int, queryStart: Int, targetStart: Int) {
        if query.isEmpty || target.isEmpty { return (0, -1, -1) }
        var bestLen = 0
        var bestQS = -1
        var bestTS = -1
        for qStart in 0..<query.count {
            for tStart in 0..<target.count {
                let cap = min(query.count - qStart, target.count - tStart)
                if cap <= bestLen { continue }
                var matchLen = 0
                while matchLen < cap && query[qStart + matchLen] == target[tStart + matchLen] {
                    matchLen += 1
                }
                if matchLen > bestLen {
                    bestLen = matchLen
                    bestQS = qStart
                    bestTS = tStart
                }
            }
        }
        return (bestLen, bestQS, bestTS)
    }

    /// One pangti's match against a query, with the position the match
    /// was found at on each side. Brief #9.10-iOS.
    public struct PangtiMatchResult {
        public let lineId: String
        public let matchLength: Int
        public let queryStart: Int
        public let targetStart: Int
    }

    /// Pick the best-matching pangti from a corpus. Tie-break: prefer match
    /// closest to END of query (most recently sung). Returns nil if best
    /// matchLength < minMatchLength OR if there's a genuine tie at the same
    /// queryEnd across multiple pangtis. ALSO returns the second-best as a
    /// runner-up for diagnostics.
    public static func findBestPangti(query: [String], corpus: [(lineId: String, fl: [String])], minMatchLength: Int) -> (best: PangtiMatchResult, runnerUp: PangtiMatchResult?)? {
        if query.isEmpty || corpus.isEmpty { return nil }
        // Compute match for every pangti
        var all: [PangtiMatchResult] = []
        for (lineId, fl) in corpus {
            let (len, qs, ts) = longestSubstringMatch(query: query, target: fl)
            all.append(PangtiMatchResult(lineId: lineId, matchLength: len, queryStart: qs, targetStart: ts))
        }
        // Sort: longest match first; tie-break by larger queryStart+matchLength (later in query = more recent)
        all.sort { a, b in
            if a.matchLength != b.matchLength { return a.matchLength > b.matchLength }
            let aEnd = a.queryStart + a.matchLength
            let bEnd = b.queryStart + b.matchLength
            return aEnd > bEnd
        }
        let best = all[0]
        guard best.matchLength >= minMatchLength else { return nil }
        // Check for genuine tie at top: same matchLength AND same queryEnd
        if all.count >= 2 {
            let second = all[1]
            let bestEnd = best.queryStart + best.matchLength
            let secondEnd = second.queryStart + second.matchLength
            if second.matchLength == best.matchLength && secondEnd == bestEnd {
                return nil  // ambiguous
            }
            return (best, second)
        }
        return (best, nil)
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
