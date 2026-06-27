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

    /// **Prefix-match window** (Brief #8.4). When transcript.count is
    /// strictly below this many chars, also accept a hit if the
    /// transcript is a *prefix* of any seed. Catches ASR truncations
    /// like "ਵਾਹਿ" (3 chars, fragment of "ਵਾਹਿਗੁਰੂ") that the
    /// substring scan would miss (the seed isn't contained in the
    /// transcript). 8 chars is one shy of the shortest single-word
    /// seed; longer fragments come from real pangtis and shouldn't
    /// short-circuit to a jaikara.
    public static let prefixMatchMaxLength: Int = 8

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

    /// Return the matching seed (display string) or nil. Always
    /// emits exactly one `[DIAG] JaikaraDetector probe …` line per
    /// call so on-device traces show every probe and its outcome.
    ///
    /// Match semantics (Brief #8.4):
    ///   1. Length gate: transcript > `maxJaikaraLength` chars
    ///      bypasses detection entirely (real pangti masquerading).
    ///   2. **Prefix path** (transcript < `prefixMatchMaxLength`):
    ///      transcript is a case-insensitive PREFIX of some seed.
    ///      Catches ASR truncations like "ਵਾਹਿ" → ਵਾਹਿਗੁਰੂ. Runs
    ///      FIRST because for fragment transcripts the substring
    ///      scan can't fire (transcript shorter than every seed).
    ///   3. Substring path: any seed is a case-insensitive substring
    ///      of the transcript. Multi-word seeds win over single-
    ///      word ones by seed-array order.
    public func detect(transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            NSLog("[DIAG] JaikaraDetector probe transcript=\"\" result=false (empty)")
            return nil
        }
        if trimmed.count > Self.maxJaikaraLength {
            NSLog("[DIAG] JaikaraDetector probe transcript=\"\(String(trimmed.prefix(30)))…\" len=\(trimmed.count) result=false (over_max_length)")
            return nil
        }

        // Prefix path — only for short fragments. Use `.anchored` so
        // the match is required at the seed's start.
        if trimmed.count < Self.prefixMatchMaxLength {
            for seed in Self.seeds {
                if seed.range(of: trimmed, options: [.caseInsensitive, .anchored]) != nil {
                    NSLog("[DIAG] JaikaraDetector probe transcript=\"\(trimmed)\" len=\(trimmed.count) type=prefix matchedSeed=\"\(seed)\" result=true")
                    return seed
                }
            }
        }

        // Substring scan (existing behaviour, used when the trimmed
        // transcript is long enough to contain a seed).
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
