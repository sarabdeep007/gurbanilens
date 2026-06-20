import Foundation

/// Devanagari → Gurmukhi transliteration. Used by the v2 voice-search
/// display pipeline: WhisperKit returns Devanagari (Hindi script) when
/// we run with `language="hi"` (the `pa→hi` workaround for Whisper-
/// small's Punjabi training gap), but Sangat expect to see the
/// recitation in **Gurmukhi script**, not Devanagari. This helper
/// produces a Gurmukhi-script rendering of the same content for
/// on-screen display while the matcher continues to receive the
/// existing Latin form from `Latin.from`.
///
/// Mapping is codepoint-level: each Devanagari scalar in U+0900..U+097F
/// has either a direct Gurmukhi equivalent in U+0A00..U+0A7F, a
/// best-effort substitute (e.g. श / ष → ਸ਼ "shasha"), or no equivalent
/// (Sanskrit-specific marks like ऋ vocalic-R) in which case we drop
/// silently rather than emit a placeholder. ASCII / whitespace / other
/// scripts pass through unchanged.
///
/// **What this is NOT.** This is not a perfect Hindi-text → idiomatic-
/// Punjabi-text translator. It's a script transliteration: same sounds,
/// different script. The matcher still does the heavy lifting of
/// mapping spoken sounds to Gurbani Pangtis via the Latin index. The
/// Gurmukhi output is purely for the "You said:" header so users see
/// the right script.
public enum Gurmukhi {

    /// Convert Devanagari text to Gurmukhi script codepoint-by-codepoint.
    /// Non-Devanagari scalars (ASCII letters, spaces, digits, etc.) pass
    /// through unchanged. Unmapped Devanagari marks are dropped silently.
    public static func fromDevanagari(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if let mapped = devanagariToGurmukhi[scalar] {
                out.append(mapped)
            } else if scalar.value >= 0x0900 && scalar.value <= 0x097F {
                // In Devanagari block but unmapped — drop silently rather
                // than emit a "?" placeholder that would confuse readers.
                continue
            } else {
                // Non-Devanagari: pass through (spaces, ASCII, already-
                // Gurmukhi from a mixed-script source, etc.).
                out.append(Character(scalar))
            }
        }
        return out
    }

    // Codepoint table built from the Unicode Devanagari (U+0900-U+097F)
    // and Gurmukhi (U+0A00-U+0A7F) blocks. Values are String so we can
    // emit multi-codepoint sequences for the few cases that need them
    // (currently none — all entries are single codepoints, but the
    // String type future-proofs the table).
    private static let devanagariToGurmukhi: [UnicodeScalar: String] = [
        // Sign marks
        "\u{0901}": "\u{0A02}",   // candrabindu → bindi (Gurmukhi has no candrabindu)
        "\u{0902}": "\u{0A02}",   // anusvara → bindi
        "\u{0903}": "\u{0A03}",   // visarga

        // Independent vowels (अ-औ)
        "\u{0905}": "\u{0A05}", "\u{0906}": "\u{0A06}",   // a, ā
        "\u{0907}": "\u{0A07}", "\u{0908}": "\u{0A08}",   // i, ī
        "\u{0909}": "\u{0A09}", "\u{090A}": "\u{0A0A}",   // u, ū
        "\u{090F}": "\u{0A0F}", "\u{0910}": "\u{0A10}",   // e, ai
        "\u{0913}": "\u{0A13}", "\u{0914}": "\u{0A14}",   // o, au
        // Sanskrit ऋ vocalic-R / ऌ vocalic-L have no Gurmukhi equivalent —
        // dropped by the unmapped-Devanagari fallback above.

        // Consonants (क-ह)
        "\u{0915}": "\u{0A15}", "\u{0916}": "\u{0A16}",   // ka, kha
        "\u{0917}": "\u{0A17}", "\u{0918}": "\u{0A18}",   // ga, gha
        "\u{0919}": "\u{0A19}",                            // ṅa
        "\u{091A}": "\u{0A1A}", "\u{091B}": "\u{0A1B}",   // ca, cha
        "\u{091C}": "\u{0A1C}", "\u{091D}": "\u{0A1D}",   // ja, jha
        "\u{091E}": "\u{0A1E}",                            // ña
        "\u{091F}": "\u{0A1F}", "\u{0920}": "\u{0A20}",   // ṭa, ṭha
        "\u{0921}": "\u{0A21}", "\u{0922}": "\u{0A22}",   // ḍa, ḍha
        "\u{0923}": "\u{0A23}",                            // ṇa
        "\u{0924}": "\u{0A24}", "\u{0925}": "\u{0A25}",   // ta, tha
        "\u{0926}": "\u{0A26}", "\u{0927}": "\u{0A27}",   // da, dha
        "\u{0928}": "\u{0A28}",                            // na
        "\u{092A}": "\u{0A2A}", "\u{092B}": "\u{0A2B}",   // pa, pha
        "\u{092C}": "\u{0A2C}", "\u{092D}": "\u{0A2D}",   // ba, bha
        "\u{092E}": "\u{0A2E}",                            // ma
        "\u{092F}": "\u{0A2F}", "\u{0930}": "\u{0A30}",   // ya, ra
        "\u{0932}": "\u{0A32}", "\u{0935}": "\u{0A35}",   // la, va
        "\u{0938}": "\u{0A38}", "\u{0939}": "\u{0A39}",   // sa, ha
        // Sanskrit श / ष → ਸ਼ (Gurmukhi shasha, U+0A36) — best-effort
        // since Punjabi doesn't have separate ś/ṣ phonemes.
        "\u{0936}": "\u{0A36}",  // śa → shasha
        "\u{0937}": "\u{0A36}",  // ṣa → shasha

        // Vowel signs (combining marks that attach to a preceding consonant)
        "\u{093E}": "\u{0A3E}", "\u{093F}": "\u{0A3F}",   // ā, i
        "\u{0940}": "\u{0A40}",                            // ī
        "\u{0941}": "\u{0A41}", "\u{0942}": "\u{0A42}",   // u, ū
        "\u{0947}": "\u{0A47}", "\u{0948}": "\u{0A48}",   // e, ai
        "\u{094B}": "\u{0A4B}", "\u{094C}": "\u{0A4C}",   // o, au
        // Devanagari short ॅ / ॉ have no direct Gurmukhi equivalent —
        // dropped by the unmapped-Devanagari fallback above.

        // Halant / virama (controls conjuncts; same role in both scripts)
        "\u{094D}": "\u{0A4D}",
        // Nukta (combining dot)
        "\u{093C}": "\u{0A3C}",

        // Pre-composed nukta-modified Devanagari → Gurmukhi equivalents.
        // ड़ (U+095C) has a dedicated Gurmukhi codepoint ੜ "rra".
        "\u{095C}": "\u{0A5C}",   // ड़ → ੜ

        // Devanagari numerals
        "\u{0966}": "\u{0A66}", "\u{0967}": "\u{0A67}",   // 0, 1
        "\u{0968}": "\u{0A68}", "\u{0969}": "\u{0A69}",   // 2, 3
        "\u{096A}": "\u{0A6A}", "\u{096B}": "\u{0A6B}",   // 4, 5
        "\u{096C}": "\u{0A6C}", "\u{096D}": "\u{0A6D}",   // 6, 7
        "\u{096E}": "\u{0A6E}", "\u{096F}": "\u{0A6F}",   // 8, 9

        // Danda / double-danda — these codepoints (U+0964, U+0965) are
        // shared between Devanagari and Gurmukhi, so passing them
        // through unchanged is correct. Explicit entries here document
        // the intent.
        "\u{0964}": "\u{0964}",
        "\u{0965}": "\u{0965}",
    ]
}
