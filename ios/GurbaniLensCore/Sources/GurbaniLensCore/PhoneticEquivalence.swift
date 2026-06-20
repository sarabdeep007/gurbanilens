import Foundation

/// Punjabi/Hindi → Latin transliteration phonetic-equivalence groups.
///
/// Whisper-small confuses voiced ↔ unvoiced plosive pairs on Indic-script
/// audio (Phase 1 + Deep's v1 on-device tests both observed b/p, g/k, d/t,
/// and j/c flipping for the same recitation across runs). The corpus's
/// English transliteration uses one canonical letter per pair, but the
/// Whisper transcript may use either letter for the same sound.
///
/// For first-letters matching this is a problem: a recitation of "babba mn"
/// might transcribe as "b…" one time and "p…" the next, giving completely
/// different first-letters strings ("bm" vs "pm") and missing the right
/// corpus line.
///
/// Fix: canonicalise every char to a single representative per group before
/// scoring. Both query and corpus first-letters strings are routed through
/// ``canonicalize(_:)`` at the same boundary so they're comparable apples-
/// to-apples. The canonical choice (p over b, k over g, etc.) is arbitrary;
/// what matters is consistency.
///
/// Groups:
///   - {b, p} → p     (voiced/unvoiced labial plosives)
///   - {g, k} → k     (voiced/unvoiced velar plosives)
///   - {d, t} → t     (voiced/unvoiced dental plosives — also covers
///                     retroflex ḍ/ṭ which Latin.from strips diacritics
///                     from, so they arrive as plain d/t here)
///   - {j, c} → c     (palatal pair — also covers ch)
///
/// Aspirated variants (kh, gh, th, dh, ch, jh, bh, ph) are not collapsed:
/// their first letter is the same as the unaspirated form, so they already
/// canonicalise correctly under these rules without losing the aspiration
/// distinction at the token level (the full-fuzzy commit-time match still
/// sees the full normalised text).
public enum PhoneticEquivalence {

    /// Map a single character to its canonical representative.
    /// Non-Latin / non-group chars pass through unchanged.
    @inline(__always)
    public static func canonicalize(_ ch: Character) -> Character {
        switch ch {
        case "b", "p": return "p"
        case "g", "k": return "k"
        case "d", "t": return "t"
        case "j", "c": return "c"
        default:       return ch
        }
    }

    /// Canonicalise every character of `s` via ``canonicalize(_:)``.
    public static func canonicalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            out.append(canonicalize(ch))
        }
        return out
    }

    /// Two chars are phonetically equivalent if either they're literally
    /// equal or they canonicalise to the same representative.
    @inline(__always)
    public static func charEquivalent(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        return canonicalize(a) == canonicalize(b)
    }
}
