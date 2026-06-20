import Foundation

/// Swift port of core/gurbanilens/asr.py:to_latin. Converts Whisper's
/// Gurmukhi or Devanagari output to plain ASCII Latin, matching BaniDB's
/// English transliteration style closely enough for the matcher to find it.
///
/// Pipeline (must match Python so port-parity holds at the asr boundary):
///   1. Detect dominant script (Gurmukhi / Devanagari)
///   2. Per-character map → IAST-with-long-vowel-markers
///   3. Double long vowels (ā→aa, ī→ee, ū→oo) BEFORE NFD strip
///   4. NFD-decompose + strip combining marks (nasals, vowel signs already
///      accounted for in step 2)
///   5. Strip word-final schwa
///
/// **Important deviation from Python:** Python uses the
/// `indic-transliteration` package which has a fully-maintained mapping
/// table. We port the subset of that table needed for Punjabi recitation
/// (consonants, vowel signs, common conjuncts). Coverage is verified
/// against Mool Mantar + Japji opening in unit tests. Edge cases
/// (rare half-forms, ਼ nukta variants) may differ from Python and need
/// adjustment when surfaced by real ASR output.
public enum Latin {

    // MARK: - Public API

    /// Convert any Indic-script text to plain ASCII Latin.
    public static func from(_ text: String) -> String {
        let script = detectScript(text)
        let iast: String
        switch script {
        case .gurmukhi:   iast = mapGurmukhi(text)
        case .devanagari: iast = mapDevanagari(text)
        case .other:      iast = text
        }
        let doubled = doubleLongVowels(iast)
        let stripped = stripCombining(doubled)
        let final = stripFinalSchwa(stripped)
        NSLog("[DIAG] Latin.from script=\(script) in.len=\(text.count) in.head100=\"\(String(text.prefix(100)))\" out.len=\(final.count) out.head100=\"\(String(final.prefix(100)))\"")
        return final
    }

    // MARK: - Script detection

    enum Script { case gurmukhi, devanagari, other }

    static func detectScript(_ text: String) -> Script {
        var g = 0, d = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A00...0x0A7F: g += 1
            case 0x0900...0x097F: d += 1
            default: break
            }
        }
        if g == 0 && d == 0 { return .other }
        return g >= d ? .gurmukhi : .devanagari
    }

    // MARK: - Long-vowel doubling

    private static let longVowelDoubles: [Character: String] = [
        "ā": "aa", "Ā": "Aa",
        "ī": "ee", "Ī": "Ee",   // BaniDB style: ī → ee, not ii
        "ū": "oo", "Ū": "Oo",   // BaniDB style: ū → oo, not uu
    ]

    static func doubleLongVowels(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            if let dbl = longVowelDoubles[ch] {
                out.append(dbl)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - NFD-strip combining marks

    static func stripCombining(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCanonicalMapping
        var out = String()
        out.reserveCapacity(decomposed.count)
        for scalar in decomposed.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            out.append(Character(scalar))
        }
        return out
    }

    // MARK: - Final-schwa stripping

    static func stripFinalSchwa(_ text: String) -> String {
        let keepEndings: Set<String> = ["aa", "ia", "ya"]
        var pieces: [String] = []
        for tok in text.split(separator: " ") {
            let s = String(tok)
            if s.count > 3 && s.hasSuffix("a") && !keepEndings.contains(where: s.hasSuffix) {
                pieces.append(String(s.dropLast()))
            } else {
                pieces.append(s)
            }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Gurmukhi → IAST mapping

    /// Subset of indic-transliteration's GURMUKHI → IAST table needed for
    /// Punjabi recitation. Each independent vowel + consonant + vowel-sign
    /// is mapped. Conjuncts handled via the halant (੍) marker.
    ///
    /// Source for the table: indic-transliteration's
    /// `sanscript/schemes/gurmukhi.py` (read at port time; if the upstream
    /// table changes, regenerate this map.)
    private static let gurmukhiMap: [UnicodeScalar: String] = [
        // Independent vowels
        "ਅ": "a", "ਆ": "ā", "ਇ": "i", "ਈ": "ī", "ਉ": "u", "ਊ": "ū",
        "ਏ": "ē", "ਐ": "ai", "ਓ": "ō", "ਔ": "au",
        // Special: Ik Onkar (ੴ) — indic-transliteration maps to "om",
        // but Sikh convention is "ik oankaar". We use the Sikh form
        // because that's what the matcher's corpus contains.
        "ੴ": "ik oankaar",
        // Consonants
        "ਕ": "ka", "ਖ": "kha", "ਗ": "ga", "ਘ": "gha", "ਙ": "ṅa",
        "ਚ": "ca", "ਛ": "cha", "ਜ": "ja", "ਝ": "jha", "ਞ": "ña",
        "ਟ": "ṭa", "ਠ": "ṭha", "ਡ": "ḍa", "ਢ": "ḍha", "ਣ": "ṇa",
        "ਤ": "ta", "ਥ": "tha", "ਦ": "da", "ਧ": "dha", "ਨ": "na",
        "ਪ": "pa", "ਫ": "pha", "ਬ": "ba", "ਭ": "bha", "ਮ": "ma",
        "ਯ": "ya", "ਰ": "ra", "ਲ": "la", "ਵ": "va",
        "ਸ": "sa", "ਹ": "ha",
        // Punjabi-specific consonants
        "ੜ": "ṛa",
        // Vowel signs (combine with preceding consonant; we strip the
        // implicit 'a' added by the consonant map and append the sign's
        // vowel)
        // (handled in transliterateConsonantSequence below)
        // Halant
        "੍": "",
        // Visarga / anusvara
        "ੰ": "ṁ", "ਂ": "ṃ", "ਃ": "ḥ",
        // Numerals — strip to digit
        "੦": "0", "੧": "1", "੨": "2", "੩": "3", "੪": "4",
        "੫": "5", "੬": "6", "੭": "7", "੮": "8", "੯": "9",
        // Punctuation
        "॥": "||", "।": "|",
    ]

    /// Vowel-sign scalars that replace the consonant's implicit 'a'.
    private static let gurmukhiVowelSign: [UnicodeScalar: String] = [
        "ਾ": "ā", "ਿ": "i", "ੀ": "ī", "ੁ": "u", "ੂ": "ū",
        "ੇ": "ē", "ੈ": "ai", "ੋ": "ō", "ੌ": "au",
    ]

    static func mapGurmukhi(_ text: String) -> String {
        return transliterate(text, baseMap: gurmukhiMap, vowelSigns: gurmukhiVowelSign,
                             halant: "੍", indicLow: 0x0A00, indicHigh: 0x0A7F)
    }

    // MARK: - Devanagari → IAST mapping

    private static let devanagariMap: [UnicodeScalar: String] = [
        // Independent vowels
        "अ": "a", "आ": "ā", "इ": "i", "ई": "ī", "उ": "u", "ऊ": "ū",
        "ऋ": "r̥", "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au",
        // Consonants
        "क": "ka", "ख": "kha", "ग": "ga", "घ": "gha", "ङ": "ṅa",
        "च": "ca", "छ": "cha", "ज": "ja", "झ": "jha", "ञ": "ña",
        "ट": "ṭa", "ठ": "ṭha", "ड": "ḍa", "ढ": "ḍha", "ण": "ṇa",
        "त": "ta", "थ": "tha", "द": "da", "ध": "dha", "न": "na",
        "प": "pa", "फ": "pha", "ब": "ba", "भ": "bha", "म": "ma",
        "य": "ya", "र": "ra", "ल": "la", "व": "va",
        "श": "śa", "ष": "ṣa", "स": "sa", "ह": "ha",
        // Nukta variants common in Punjabi-via-Devanagari
        "क़": "qa", "ख़": "ḵha", "ग़": "ġa", "ज़": "za", "ड़": "ṛa",
        "ढ़": "ṛha", "य़": "fa",
        // Halant / virama
        "्": "",
        // Anusvara / visarga
        "ं": "ṃ", "ः": "ḥ", "ँ": "m̐",
        // Devanagari numerals
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4",
        "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
        // Punctuation
        "॥": "||", "।": "|",
    ]

    private static let devanagariVowelSign: [UnicodeScalar: String] = [
        "ा": "ā", "ि": "i", "ी": "ī", "ु": "u", "ू": "ū",
        "ृ": "r̥", "े": "e", "ै": "ai", "ो": "o", "ौ": "au",
    ]

    static func mapDevanagari(_ text: String) -> String {
        return transliterate(text, baseMap: devanagariMap, vowelSigns: devanagariVowelSign,
                             halant: "्", indicLow: 0x0900, indicHigh: 0x097F)
    }

    // MARK: - Core transliteration loop

    /// Walk through `text` scalar-by-scalar. When we see a consonant we
    /// emit its mapped form (which ends in "a"); if the next scalar is a
    /// vowel sign, replace the trailing "a" with the sign's vowel; if it's
    /// the halant, drop the trailing "a" entirely.
    static func transliterate(
        _ text: String,
        baseMap: [UnicodeScalar: String],
        vowelSigns: [UnicodeScalar: String],
        halant: UnicodeScalar,
        indicLow: UInt32,
        indicHigh: UInt32
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String()
        out.reserveCapacity(scalars.count * 2)

        var i = 0
        while i < scalars.count {
            let s = scalars[i]

            // Vowel sign attaches to previous emitted consonant — handle below.
            if vowelSigns[s] != nil {
                if let v = vowelSigns[s], !out.isEmpty, out.hasSuffix("a") {
                    out.removeLast()
                    out.append(v)
                } else if let v = vowelSigns[s] {
                    out.append(v)
                }
                i += 1
                continue
            }

            // Halant removes the trailing 'a' from the previous consonant
            // (or maps to empty if there's no 'a' to remove).
            if s == halant {
                if out.hasSuffix("a") { out.removeLast() }
                i += 1
                continue
            }

            // Direct map
            if let mapped = baseMap[s] {
                out.append(mapped)
                i += 1
                continue
            }

            // Pass through anything we don't recognise (ASCII, spaces,
            // punctuation that wasn't in the map).
            let isInIndicRange = s.value >= indicLow && s.value <= indicHigh
            if !isInIndicRange {
                out.append(Character(s))
            }
            // If it IS in the indic range but unmapped, we drop it
            // silently — better than emitting a "?" placeholder that
            // confuses matching.
            i += 1
        }
        return out
    }
}
