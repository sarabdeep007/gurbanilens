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
        // Brief #9.13: Convert AnmolLipi → proper Unicode Gurmukhi
        // FIRST using the canonical anvaad-js port, then extract first
        // letters from the Unicode result. The previous single-char-map
        // approach skipped whole words that start with sihari `i` (e.g.
        // `iqin` for ਤਿਨਿ) because `i` is not a base letter; this is
        // the standard AnmolLipi sihari-before-consonant convention.
        let unicode = Gurmukhi.fromAnmolLipi(text)
        return extract(unicode)
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

    // MARK: - Safely-unique starters (Brief #9.16)

    /// Compute the safely-unique starter map for a shabad's FL signatures.
    /// Returns letter → lineId for letters that are some pangti's first FL letter
    /// AND appear nowhere else in any other pangti's FL signature. Brief #9.16.
    ///
    /// A letter L qualifies as pangti X's safely-unique starter iff:
    ///   1. `fl_X[0] == L` (L is X's first letter), AND
    ///   2. L does NOT appear at ANY position in any other `fl_j` (j != X)
    ///
    /// By construction, seeing L in the ASR partial FL is proof the raagi is
    /// singing X — zero false-positive risk.
    public static func safeUniqueStarters(corpus: [(lineId: String, fl: [String])]) -> [String: String] {
        if corpus.isEmpty { return [:] }
        // Step 1: count all letter occurrences across all pangtis (any position).
        // Deduplicate within a single pangti so repeated letters in the same
        // pangti don't inflate the count.
        var globalCount: [String: Int] = [:]
        for (_, fl) in corpus {
            let uniqueInPangti = Set(fl)
            for letter in uniqueInPangti {
                globalCount[letter, default: 0] += 1
            }
        }
        // Step 2: for each pangti's starter, check if it occurs exactly once
        // in globalCount — i.e. it appears only in this one pangti (and by
        // construction here, at position 0).
        var result: [String: String] = [:]
        for (lineId, fl) in corpus {
            guard let starter = fl.first else { continue }
            if globalCount[starter] == 1 {
                result[starter] = lineId
            }
        }
        return result
    }

    /// Scan trailing N letters of queryFL for any safely-unique starter.
    /// Returns the matched (letter, lineId) for the LATEST trailing letter
    /// that hits. Returns nil if no trailing letter matches. Brief #9.16.
    ///
    /// "Latest wins" biases toward the raagi's most recent word — the safe-
    /// unique letter is proof they're singing that pangti NOW, not that they
    /// mentioned it a moment ago.
    public static func findTrailingSafeUniqueStarter(
        queryFL: [String],
        safeStarters: [String: String],
        trailingWindow: Int
    ) -> (letter: String, lineId: String)? {
        if queryFL.isEmpty || safeStarters.isEmpty { return nil }
        let windowSize = min(trailingWindow, queryFL.count)
        let startIdx = queryFL.count - windowSize
        // Iterate trailing → recent first (rightmost is most recent).
        for i in stride(from: queryFL.count - 1, through: startIdx, by: -1) {
            let letter = queryFL[i]
            if let lineId = safeStarters[letter] {
                return (letter, lineId)
            }
        }
        return nil
    }

    // MARK: - Safely-unique starter bigrams (Brief #9.19)

    /// Compute the safely-unique starter-bigram map for a shabad's FL signatures.
    /// Returns bigramKey → lineId where bigramKey encodes a pair as "L1|L2".
    /// A bigram (L1, L2) qualifies iff (a) it's some pangti X's first two FL
    /// letters AND (b) the consecutive pair (L1, L2) does not appear at any
    /// position in any other pangti's FL. Zero false-positive guarantee analogous
    /// to safeUniqueStarters. Brief #9.19.
    public static func safeUniqueBigramStarters(corpus: [(lineId: String, fl: [String])]) -> [String: String] {
        if corpus.isEmpty { return [:] }
        // Step 1: count each consecutive bigram across all pangtis, deduped within
        // a single pangti (a bigram appearing twice in the same pangti counts once).
        var globalCount: [String: Int] = [:]
        for (_, fl) in corpus {
            if fl.count < 2 { continue }
            var seenInPangti = Set<String>()
            for i in 0..<(fl.count - 1) {
                let key = "\(fl[i])|\(fl[i + 1])"
                if seenInPangti.insert(key).inserted {
                    globalCount[key, default: 0] += 1
                }
            }
        }
        // Step 2: for each pangti's starter bigram, check total count == 1.
        var result: [String: String] = [:]
        for (lineId, fl) in corpus {
            guard fl.count >= 2 else { continue }
            let starterKey = "\(fl[0])|\(fl[1])"
            if globalCount[starterKey] == 1 {
                result[starterKey] = lineId
            }
        }
        return result
    }

    /// Scan trailing N letters of queryFL for any safely-unique starter bigram.
    /// Checks each consecutive bigram in the trailing slice, RIGHT-TO-LEFT (most
    /// recent bigram first). Returns the matched (bigram-as-tuple, lineId) for
    /// the rightmost hit. Returns nil if no trailing bigram is a safe starter.
    /// Brief #9.19.
    public static func findTrailingSafeUniqueBigram(
        queryFL: [String],
        safeBigrams: [String: String],
        trailingWindow: Int
    ) -> (bigram: (String, String), lineId: String)? {
        if queryFL.count < 2 || safeBigrams.isEmpty { return nil }
        let windowSize = min(trailingWindow, queryFL.count)
        // Trailing slice is the last `windowSize` letters. Bigrams in that slice
        // start at positions [queryFL.count - windowSize ... queryFL.count - 2].
        let startIdx = queryFL.count - windowSize
        let lastBigramStart = queryFL.count - 2
        if lastBigramStart < startIdx { return nil }
        // Iterate right-to-left over bigram start positions.
        for i in stride(from: lastBigramStart, through: startIdx, by: -1) {
            let a = queryFL[i]
            let b = queryFL[i + 1]
            let key = "\(a)|\(b)"
            if let lineId = safeBigrams[key] {
                return ((a, b), lineId)
            }
        }
        return nil
    }

    // MARK: - First-two-word signatures (Brief #9.26 5)

    /// Compute per-shabad first-two-word signatures: pangti-starter
    /// bigrams that are unique **among starters** (not globally).
    /// Returns bigramKey `"L1|L2"` → lineId for each starter bigram
    /// (L1 = fl[0], L2 = fl[1]) that occurs at position 0 in
    /// exactly one pangti.
    ///
    /// Distinct from ``safeUniqueBigramStarters``:
    ///   - safeUniqueBigramStarters requires the pair to be absent
    ///     from every OTHER pangti's full FL universe — zero false-
    ///     positive risk.
    ///   - firstTwoWordSignatures only requires uniqueness AMONG
    ///     starter bigrams — looser. Fires more often but carries a
    ///     small false-positive risk when another pangti's BODY
    ///     contains the same bigram. Acceptable within-shabad since
    ///     the outcome is only a line jump inside the current
    ///     shabad; cross-shabad detection stays server-driven.
    ///
    /// Deep's brief rationale: raagis often start a pangti with
    /// clean opening consonants even during alaap; a two-word
    /// signature is precise enough to fingerprint most pangtis
    /// uniquely within a shabad (~5-15 pangtis per shabad).
    public static func firstTwoWordSignatures(corpus: [(lineId: String, fl: [String])]) -> [String: String] {
        if corpus.isEmpty { return [:] }
        var starterCounts: [String: Int] = [:]
        for (_, fl) in corpus {
            guard fl.count >= 2 else { continue }
            let key = "\(fl[0])|\(fl[1])"
            starterCounts[key, default: 0] += 1
        }
        var result: [String: String] = [:]
        for (lineId, fl) in corpus {
            guard fl.count >= 2 else { continue }
            let key = "\(fl[0])|\(fl[1])"
            if starterCounts[key] == 1 {
                result[key] = lineId
            }
        }
        return result
    }

    // MARK: - Safe-unique first-two-word signatures (Brief #9.28)

    /// Compute the SAFE-UNIQUE first-two-word signature map for a
    /// shabad — the tightened variant of ``firstTwoWordSignatures``.
    /// A starter bigram (fl[0], fl[1]) of pangti X qualifies iff:
    ///   1. No other pangti in the shabad has (fl[0], fl[1]) as its
    ///      starter (unique among starters), AND
    ///   2. The consecutive pair (fl[0], fl[1]) does NOT appear at
    ///      ANY position in any OTHER pangti's FL — including the
    ///      body. Same-pangti body repetition is fine: the raagi is
    ///      already on the correct line when the trailing bigram
    ///      fires.
    ///
    /// This restores the zero-false-positive-within-shabad guarantee
    /// that Brief #9.19's `safeUniqueBigramStarters` had. #9.26's
    /// `firstTwoWordSignatures` relaxed to "unique-among-starters"
    /// only, which caused Deep's post-#9.27 iPhone log — the highlight
    /// walked across 6 different wrong lineIds while he sang D7PD
    /// because the ASR partial's trailing bigram matched OTHER pangtis'
    /// starter bigrams that also happened to appear in their neighbors'
    /// bodies.
    ///
    /// Structurally equivalent output to ``safeUniqueBigramStarters``
    /// under typical corpora; kept as a separate API so the call-site
    /// intent (fingerprint a pangti's clean opening two-word signature)
    /// stays explicit and future divergence is possible without
    /// re-plumbing.
    ///
    /// Brief #9.28.
    public static func safeUniqueFirstTwoWordSigs(corpus: [(lineId: String, fl: [String])]) -> [String: String] {
        if corpus.isEmpty { return [:] }
        // Filter 1: starter uniqueness. Same criterion as
        // ``firstTwoWordSignatures``.
        var starterCounts: [String: Int] = [:]
        var starterOwner: [String: String] = [:]
        for (lineId, fl) in corpus {
            guard fl.count >= 2 else { continue }
            let key = "\(fl[0])|\(fl[1])"
            starterCounts[key, default: 0] += 1
            starterOwner[key] = lineId
        }
        // Filter 2: body-absence in OTHER pangtis. Iterates every
        // consecutive pair (starter or body) in every non-owning
        // pangti and excludes bigrams that collide.
        var result: [String: String] = [:]
        for (key, ownerId) in starterOwner {
            guard starterCounts[key] == 1 else { continue }
            var appearsElsewhere = false
            for (lid, fl) in corpus {
                if lid == ownerId { continue }
                if fl.count < 2 { continue }
                for i in 0..<(fl.count - 1) {
                    let otherKey = "\(fl[i])|\(fl[i + 1])"
                    if otherKey == key {
                        appearsElsewhere = true
                        break
                    }
                }
                if appearsElsewhere { break }
            }
            if !appearsElsewhere {
                result[key] = ownerId
            }
        }
        return result
    }

    /// Scan trailing N letters of queryFL for any first-two-word
    /// signature. Checks each consecutive bigram in the trailing
    /// slice RIGHT-TO-LEFT (most recent bigram first). Returns the
    /// matched pangti for the rightmost hit, else nil. Two-letter
    /// minimum in the query — a single-letter partial cannot form a
    /// bigram and correctly returns nil. Brief #9.26 5.
    ///
    /// Brief #9.28: callers should feed this the map returned by
    /// ``safeUniqueFirstTwoWordSigs``, NOT the raw
    /// ``firstTwoWordSignatures`` output. The signature is unchanged
    /// because both maps share the `[bigramKey: lineId]` shape.
    public static func findTrailingFirstTwoWordSig(
        queryFL: [String],
        firstTwoWordSigs: [String: String],
        trailingWindow: Int
    ) -> (bigram: (String, String), lineId: String)? {
        if queryFL.count < 2 || firstTwoWordSigs.isEmpty { return nil }
        let windowSize = min(trailingWindow, queryFL.count)
        let startIdx = queryFL.count - windowSize
        let lastBigramStart = queryFL.count - 2
        if lastBigramStart < startIdx { return nil }
        for i in stride(from: lastBigramStart, through: startIdx, by: -1) {
            let a = queryFL[i]
            let b = queryFL[i + 1]
            let key = "\(a)|\(b)"
            if let lineId = firstTwoWordSigs[key] {
                return ((a, b), lineId)
            }
        }
        return nil
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
