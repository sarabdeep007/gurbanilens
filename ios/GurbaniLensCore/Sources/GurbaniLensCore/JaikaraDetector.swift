import Foundation

/// Jaikara recognition for Raagi Mode. Brief #8 Commit 3, refined
/// through Brief #8.4 (prefix path) → #8.6 (min-length floor) →
/// Brief #9.26 (5a expanded seeds, 5b guru-token guard, 5c
/// Mool-Mantar context suppression).
///
/// In a kirtan setting the raagi periodically calls out a jaikara —
/// "ਵਾਹਿਗੁਰੂ", "ਬੋਲੇ ਸੋ ਨਿਹਾਲ", etc. These are devotional
/// punctuations, NOT pangtis to look up in SGGS. If we pass them
/// through the matcher we'd burn a round-trip on a no-op and the
/// previously-displayed shabad would briefly flicker.
///
/// Detection contract:
///   - Input is the Gurmukhi transcript from the ASR pipeline.
///   - Match is case-insensitive substring (Gurmukhi doesn't have
///     case but normalisation collapses zero-width joiners etc.).
///   - We ONLY consider jaikara hits when the transcript is short
///     (≤ `maxJaikaraLength`) — otherwise a long pangti happening
///     to contain "ਵਾਹਿਗੁਰੂ" as a word would be misdetected.
///   - Brief #9.26 5c: caller may supply the currently-displayed
///     pangti text as `currentLineText`. If it contains any of the
///     `contextSuppressionMarkers`, jaikara detection is short-
///     circuited — Gurbani context beats jaikara context. Fixes
///     Deep's observation of a spurious "ਅਕਾਲ" banner firing during
///     Mool Mantar's "ਅਕਾਲ ਮੂਰਤਿ" line.
///   - First matching seed wins. Returns the seed string (display
///     text) or nil.
public struct JaikaraDetector: Sendable {

    /// Maximum length (in characters) of a transcript that's allowed
    /// to be classified as a pure jaikara. Above this we assume the
    /// utterance is a real pangti that happens to contain a jaikara
    /// word. Brief #9.26 5a raised 24 → 45 to accommodate the full
    /// "ਵਾਹਿਗੁਰੂ ਜੀ ਕਾ ਖਾਲਸਾ ਵਾਹਿਗੁਰੂ ਜੀ ਕੀ ਫ਼ਤਹਿ" long-form
    /// jaikara (~39 chars) and multi-word Guru-name jaikaras.
    public static let maxJaikaraLength: Int = 45

    /// **Prefix-match window**. When transcript.count is ≤ this many
    /// chars, also accept a hit if the transcript is a *prefix* of
    /// any seed. Catches ASR truncations like "ਵਾਹਿ" (4 chars,
    /// fragment of "ਵਾਹਿਗੁਰੂ") as well as partial jaikara recitations
    /// like "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ" (~19 chars) that indicate the
    /// raagi has begun the Teg Bahadur jaikara without yet finishing
    /// "ਸਾਹਿਬ ਜੀ". Brief #9.26 5a raised 8 → 20; the greedy-prefix
    /// false positive that motivated the tight gate is now blocked
    /// by the `seedSpecificToken` guard (5b).
    public static let prefixMatchMaxLength: Int = 20

    /// **Prefix-match minimum length** (Brief #8.6). Single- and
    /// two-character transcripts are short-circuited to "noise":
    /// they're statistically indistinguishable from background
    /// breath / mic clicks / VAD false-starts.
    public static let prefixMatchMinLength: Int = 3

    /// Seed phrases. Ordered loosely by likely frequency so the
    /// short single-word jaikaras don't shadow the multi-word ones.
    /// Brief #9.26 5a appended ten additional seeds: the remaining
    /// nine Guru-name jaikaras (Angad through Gobind Singh) and the
    /// long-form "Waheguru Ji Ka Khalsa / Ki Fateh".
    public static let seeds: [String] = [
        "ਵਾਹਿਗੁਰੂ ਵਾਹਿਗੁਰੂ",
        "ਸਤਿ ਨਾਮੁ ਵਾਹਿਗੁਰੂ",
        "ਬੋਲੇ ਸੋ ਨਿਹਾਲ",
        "ਸਤਿ ਸ੍ਰੀ ਅਕਾਲ",
        "ਧੰਨ ਗੁਰੂ ਨਾਨਕ ਦੇਵ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਅੰਗਦ ਦੇਵ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਅਮਰ ਦਾਸ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਰਾਮ ਦਾਸ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਅਰਜਨ ਦੇਵ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਹਰਗੋਬਿੰਦ ਸਾਹਿਬ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਹਰ ਰਾਇ ਸਾਹਿਬ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਹਰਿ ਕ੍ਰਿਸ਼ਨ ਸਾਹਿਬ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਗੋਬਿੰਦ ਸਿੰਘ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਗ੍ਰੰਥ ਸਾਹਿਬ ਜੀ",
        "ਵਾਹਿਗੁਰੂ ਜੀ ਕਾ ਖਾਲਸਾ ਵਾਹਿਗੁਰੂ ਜੀ ਕੀ ਫ਼ਤਹਿ",
        "ਵਾਹਿਗੁਰੂ",
        "ਅਕਾਲ",
        "ਓਅੰਕਾਰ",
    ]

    /// Brief #9.26 5b: seeds that share the "ਧੰਨ ਗੁਰੂ …" prefix are
    /// only accepted when the ASR transcript ALSO contains the
    /// specific disambiguating Guru-name token. Blocks the greedy
    /// prefix "ਧੰਨ ਗੁਰੂ" from resolving to Nanak Dev whenever the
    /// raagi is actually mid-way through calling out a different
    /// Guru's jaikara. The map's keys are the seed strings; values
    /// are the mandatory disambiguating tokens. Seeds not in the
    /// map (e.g. "ਵਾਹਿਗੁਰੂ", "ਬੋਲੇ ਸੋ ਨਿਹਾਲ") have no additional
    /// token requirement.
    public static let seedSpecificToken: [String: String] = [
        "ਧੰਨ ਗੁਰੂ ਨਾਨਕ ਦੇਵ ਜੀ":           "ਨਾਨਕ",
        "ਧੰਨ ਗੁਰੂ ਅੰਗਦ ਦੇਵ ਜੀ":          "ਅੰਗਦ",
        "ਧੰਨ ਗੁਰੂ ਅਮਰ ਦਾਸ ਜੀ":           "ਅਮਰ",
        "ਧੰਨ ਗੁਰੂ ਰਾਮ ਦਾਸ ਜੀ":            "ਰਾਮ",
        "ਧੰਨ ਗੁਰੂ ਅਰਜਨ ਦੇਵ ਜੀ":          "ਅਰਜਨ",
        "ਧੰਨ ਗੁਰੂ ਹਰਗੋਬਿੰਦ ਸਾਹਿਬ ਜੀ":    "ਹਰਗੋਬਿੰਦ",
        "ਧੰਨ ਗੁਰੂ ਹਰ ਰਾਇ ਸਾਹਿਬ ਜੀ":      "ਹਰ ਰਾਇ",
        "ਧੰਨ ਗੁਰੂ ਹਰਿ ਕ੍ਰਿਸ਼ਨ ਸਾਹਿਬ ਜੀ": "ਕ੍ਰਿਸ਼ਨ",
        "ਧੰਨ ਗੁਰੂ ਤੇਗ ਬਹਾਦੁਰ ਸਾਹਿਬ ਜੀ":  "ਤੇਗ",
        "ਧੰਨ ਗੁਰੂ ਗੋਬਿੰਦ ਸਿੰਘ ਜੀ":       "ਗੋਬਿੰਦ",
        "ਧੰਨ ਗੁਰੂ ਗ੍ਰੰਥ ਸਾਹਿਬ ਜੀ":       "ਗ੍ਰੰਥ",
    ]

    /// Brief #9.26 5c: Gurbani-context suppression markers. When the
    /// currently-displayed pangti text contains any of these
    /// substrings, jaikara detection is fully suppressed. Focused on
    /// the specific bug Deep observed — the "ਅਕਾਲ" banner firing
    /// while Mool Mantar's "ਅਕਾਲ ਮੂਰਤਿ" was on screen. Kept narrow
    /// on purpose: broadening to full jaikara word tokens would
    /// over-suppress since many pangtis contain jaikara-adjacent
    /// words. Grow the list as concrete false-positives surface.
    public static let contextSuppressionMarkers: [String] = [
        "ਅਕਾਲ ਮੂਰਤਿ",
        "ਅਕਾਲ ਪੁਰਖ",
    ]

    public init() {}

    /// Return the matching seed (display string) or nil. Always
    /// emits exactly one `[DIAG] JaikaraDetector probe …` line per
    /// call so on-device traces show every probe and its outcome.
    ///
    /// - Parameters:
    ///   - transcript: Gurmukhi ASR partial.
    ///   - currentLineText: Brief #9.26 5c — optional Gurmukhi text
    ///     of the currently-displayed pangti. When provided and it
    ///     matches any of the ``contextSuppressionMarkers``, this
    ///     call returns nil.
    public func detect(transcript: String, currentLineText: String? = nil) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSLog("[DIAG] JaikaraDetector probe transcript=\"\" result=false (empty)")
            return nil
        }

        // Brief #9.26 5c: context guard.
        if let context = currentLineText,
           let marker = Self.contextSuppressionMarkers.first(where: {
               context.range(of: $0, options: [.caseInsensitive]) != nil
           }) {
            NSLog("[DIAG] JaikaraDetector suppressed by context marker=\"\(marker)\" currentLine=\"\(String(context.prefix(40)))\" transcript=\"\(String(trimmed.prefix(30)))\"")
            return nil
        }

        if trimmed.count > Self.maxJaikaraLength {
            NSLog("[DIAG] JaikaraDetector probe transcript=\"\(String(trimmed.prefix(30)))…\" len=\(trimmed.count) result=false (over_max_length)")
            return nil
        }
        if trimmed.count < Self.prefixMatchMinLength {
            NSLog("[DIAG] JaikaraDetector probe transcript=\"\(trimmed)\" len=\(trimmed.count) type=belowMin REJECTED (below min length \(Self.prefixMatchMinLength))")
            return nil
        }

        // Prefix path — transcript is a prefix of some seed. Brief
        // #9.26 5b: seeds requiring a specific Guru-name token are
        // skipped when the transcript lacks that token, so the
        // greedy-prefix "ਧੰਨ ਗੁਰੂ" no longer collapses to Nanak
        // Dev whenever the raagi is heading toward a different
        // Guru's name.
        if trimmed.count <= Self.prefixMatchMaxLength {
            for seed in Self.seeds {
                if seed.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil {
                    if let token = Self.seedSpecificToken[seed],
                       trimmed.range(of: token, options: [.caseInsensitive]) == nil {
                        // Prefix matched but disambiguating token missing.
                        continue
                    }
                    NSLog("[DIAG] JaikaraDetector probe transcript=\"\(trimmed)\" len=\(trimmed.count) type=prefix matchedSeed=\"\(seed)\" result=true")
                    return seed
                }
            }
        }

        // Substring path — any seed is a substring of the transcript.
        // Multi-word seeds win over single-word ones by seed-array
        // order. Token check is redundant here (containing the full
        // seed necessarily contains its token) but kept for symmetry.
        for seed in Self.seeds {
            if trimmed.range(of: seed, options: [.caseInsensitive]) != nil {
                NSLog("[DIAG] JaikaraDetector probe transcript=\"\(trimmed)\" len=\(trimmed.count) type=substring matchedSeed=\"\(seed)\" result=true")
                return seed
            }
        }

        NSLog("[DIAG] JaikaraDetector probe transcript=\"\(trimmed)\" len=\(trimmed.count) result=false")
        return nil
    }
}
