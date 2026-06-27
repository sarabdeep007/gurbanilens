import Foundation

/// Jaikara recognition for Raagi Mode. Brief #8 Commit 3.
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
///     (≤ 20 chars) — otherwise a long pangti happening to contain
///     "ਵਾਹਿਗੁਰੂ" as a word would be misdetected. Real jaikaras
///     fit in 20 chars easily; the longest seed below is 24 chars
///     but normalises to ~20 once trimmed.
///   - First matching seed wins. Returns the seed string (display
///     text) or nil.
///
/// Seed list (8 phrases, hardcoded for v1 per Brief #8). Drawn from
/// the most common kirtan-darbar jaikaras. Configurable list is a v2
/// concern.
public struct JaikaraDetector: Sendable {

    /// Maximum length (in characters) of a transcript that's allowed
    /// to be classified as a pure jaikara. Above this we assume the
    /// utterance is a real pangti that happens to contain a jaikara
    /// word.
    public static let maxJaikaraLength: Int = 24

    /// v1 seed phrases. Ordered loosely by likely frequency so the
    /// short single-word jaikaras don't shadow the multi-word ones.
    public static let seeds: [String] = [
        "ਵਾਹਿਗੁਰੂ ਵਾਹਿਗੁਰੂ",
        "ਸਤਿ ਨਾਮੁ ਵਾਹਿਗੁਰੂ",
        "ਬੋਲੇ ਸੋ ਨਿਹਾਲ",
        "ਸਤਿ ਸ੍ਰੀ ਅਕਾਲ",
        "ਧੰਨ ਗੁਰੂ ਨਾਨਕ ਦੇਵ ਜੀ",
        "ਧੰਨ ਗੁਰੂ ਗ੍ਰੰਥ ਸਾਹਿਬ ਜੀ",
        "ਵਾਹਿਗੁਰੂ",
        "ਅਕਾਲ",
        "ਓਅੰਕਾਰ",
    ]

    public init() {}

    /// Return the matching seed (display string) or nil.
    public func detect(transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Length gate — long utterances bypass jaikara detection so
        // a pangti containing "ਵਾਹਿਗੁਰੂ" as a word isn't misdetected.
        if trimmed.count > Self.maxJaikaraLength { return nil }
        // Case-insensitive substring scan. Multi-word seeds first
        // (already ordered in the seed array) — if both
        // "ਵਾਹਿਗੁਰੂ ਵਾਹਿਗੁਰੂ" and "ਵਾਹਿਗੁਰੂ" would match,
        // the longer / more specific wins.
        for seed in Self.seeds {
            if trimmed.range(of: seed, options: [.caseInsensitive]) != nil {
                return seed
            }
        }
        return nil
    }
}
