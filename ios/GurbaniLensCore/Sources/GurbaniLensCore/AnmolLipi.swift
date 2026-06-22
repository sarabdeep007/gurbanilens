import Foundation

extension Gurmukhi {
    /// Convert Anmol Lipi (legacy proprietary ASCII-based Gurmukhi font
    /// encoding) to proper Unicode Gurmukhi. The BaniDB-derived corpus
    /// we bundle stores `line.gurmukhi` in Anmol Lipi format — strings
    /// like `"] jpu ]"` and `"Awid scu jugwid scu ]"` need this
    /// transformation before iOS's system font can render them, or
    /// they'll appear as ASCII garbage on screen.
    ///
    /// Port of Khalis Foundation's `anvaad-js` (`src/unicode.js`,
    /// GPL-3.0 — github.com/KhalisFoundation/anvaad-js). The verbatim
    /// JS reference is in `scripts/anvaad-investigation/anvaad-unicode.js`
    /// for review/audit; this Swift port mirrors its structure 1:1.
    ///
    /// **Why runtime, not build-time.** Pre-converting the bundled
    /// SQLite corpus would skip the per-row work and is cleaner, but
    /// requires regenerating the dataset + updating
    /// `scripts/fetch_corpus.py`. Deferred to a v2 dispatch — this
    /// fix unblocks the v1 search-result rendering today.
    public static func fromAnmolLipi(_ text: String) -> String {
        return AnmolLipi.unicode(text, simplify: false)
    }
}

/// Implementation namespace for the anvaad-js port. Kept `internal` so
/// the public surface is just `Gurmukhi.fromAnmolLipi`. `simplify` is
/// exposed for the test target to exercise the supplementary-char
/// branch (s/j/K/g/P/l + æ → ਸ਼/ਜ਼/ਖ਼/ਗ਼/ਫ਼/ਲ਼) without going through the
/// extension wrapper.
enum AnmolLipi {

    /// Convert Anmol Lipi → Unicode Gurmukhi.
    /// 1:1 port of `unicode(text, false, simplify)` in anvaad-js.
    static func unicode(_ text: String, simplify: Bool = false) -> String {
        if text.isEmpty { return text }

        // Pre-clean: drop characters that are decorative-only or
        // composition markers without a Unicode equivalent.
        var str = text
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "Ø", with: "")
            .replacingOccurrences(of: "Æ", with: "")

        // ASCII corrections — Anmol Lipi sometimes orders the post-base
        // vowel mark before the consonant in the source. Replace each
        // reversed pair with the canonical order so the per-char loop
        // below sees the right sequence.
        for pair in asciiCorrections {
            let reversed = String(pair.reversed())
            str = str.replacingOccurrences(of: reversed, with: pair)
        }

        let chars = Array(str)
        var out = ""
        out.reserveCapacity(text.count * 2)

        var j = 0
        while j < chars.count {
            let currentChar = chars[j]
            let nextChar: Character? = j + 1 < chars.count ? chars[j + 1] : nil
            let nextNextChar: Character? = j + 2 < chars.count ? chars[j + 2] : nil

            if currentChar == "i" {
                // Sihari prefix swap: Anmol Lipi writes `i` before the
                // consonant, Unicode wants the sihari (ਿ) after.
                if let nc = nextChar {
                    if nc == "e" {
                        out += "ਇ"
                    } else if let nnc = nextNextChar, halfChars.contains(nnc) {
                        appendMapped(nc, to: &out)
                        appendMapped(nnc, to: &out)
                        out += "ਿ"
                        j += 1
                    } else {
                        appendMapped(nc, to: &out)
                        out += "ਿ"
                    }
                    j += 1
                } else {
                    appendMapped(currentChar, to: &out)
                }
            } else if currentChar == "a" {
                switch nextChar {
                case "u": out += "ਉ"; j += 1
                case "U": out += "ਊ"; j += 1
                default: appendMapped(currentChar, to: &out)
                }
            } else if currentChar == "A" {
                switch nextChar {
                case "w": out += "ਆ"; j += 1
                case "W": out += "ਆਂ"; j += 1
                case "Y": out += "ਐ"; j += 1
                case "O": out += "ਔ"; j += 1
                default: appendMapped(currentChar, to: &out)
                }
            } else if currentChar == "e" {
                switch nextChar {
                case "I": out += "ਈ"; j += 1
                case "y": out += "ਏ"; j += 1
                default: appendMapped(currentChar, to: &out)
                }
            } else if currentChar == "1" && nextChar == "E" && nextNextChar == "å" {
                out += "ੴ"
                j += 2
            } else if currentChar == "u" && nextChar == "o" {
                out += "ੋੁ"
                j += 1
            } else if simplify && nextChar == "æ" {
                switch currentChar {
                case "s": out += "ਸ਼"; j += 1
                case "j": out += "ਜ਼"; j += 1
                case "K": out += "ਖ਼"; j += 1
                case "g": out += "ਗ਼"; j += 1
                case "P": out += "ਫ਼"; j += 1
                case "l": out += "ਲ਼"; j += 1
                default: appendMapped(currentChar, to: &out)
                }
            } else {
                appendMapped(currentChar, to: &out)
            }

            j += 1
        }

        return out
    }

    private static func appendMapped(_ c: Character, to out: inout String) {
        if let v = mapping[c] {
            out += v
        } else {
            out.append(c)
        }
    }

    // MARK: - Tables (verbatim from anvaad-js src/unicode.js)

    /// Per-character Anmol Lipi → Unicode mapping. Multi-codepoint
    /// outputs (`H → ੍ਹ`, `ƒ → ਨੂੰ`) are intentional.
    static let mapping: [Character: String] = [
        "a": "ੳ",
        "A": "ਅ",
        "s": "ਸ",
        "S": "ਸ਼",
        "d": "ਦ",
        "D": "ਧ",
        "f": "ਡ",
        "F": "ਢ",
        "g": "ਗ",
        "G": "ਘ",
        "h": "ਹ",
        "H": "੍ਹ",
        "j": "ਜ",
        "J": "ਝ",
        "k": "ਕ",
        "K": "ਖ",
        "l": "ਲ",
        "L": "ਲ਼",
        "q": "ਤ",
        "Q": "ਥ",
        "w": "ਾ",
        "W": "ਾਂ",
        "e": "ੲ",
        "E": "ਓ",
        "r": "ਰ",
        "R": "੍ਰ",
        "®": "੍ਰ",
        "t": "ਟ",
        "T": "ਠ",
        "y": "ੇ",
        "Y": "ੈ",
        "u": "ੁ",
        "ü": "ੁ",
        "U": "ੂ",
        "¨": "ੂ",
        "i": "ਿ",
        "I": "ੀ",
        "o": "ੋ",
        "O": "ੌ",
        "p": "ਪ",
        "P": "ਫ",
        "z": "ਜ਼",
        "Z": "ਗ਼",
        "x": "ਣ",
        "X": "ਯ",
        "c": "ਚ",
        "C": "ਛ",
        "v": "ਵ",
        "V": "ੜ",
        "b": "ਬ",
        "B": "ਭ",
        "n": "ਨ",
        "ƒ": "ਨੂੰ",
        "N": "ਂ",
        "ˆ": "ਂ",
        "m": "ਮ",
        "M": "ੰ",
        "µ": "ੰ",
        "`": "ੱ",
        "~": "ੱ",
        "¤": "ੱ",
        "Í": "੍ਵ",
        "ç": "੍ਚ",
        "†": "੍ਟ",
        "œ": "੍ਤ",
        "˜": "੍ਨ",
        "´": "ੵ",
        "Ï": "ੵ",
        "æ": "਼",
        "Î": "੍ਯ",
        "ì": "ਯ",
        "í": "੍ਯ",
        "1": "੧",
        "2": "੨",
        "3": "੩",
        "4": "੪",
        "5": "੫",
        "6": "੬",
        "^": "ਖ਼",
        "7": "੭",
        "&": "ਫ਼",
        "8": "੮",
        "9": "੯",
        "0": "੦",
        "\\": "ਞ",
        "|": "ਙ",
        "[": "।",
        "]": "॥",
        "<": "ੴ",
        "¡": "ੴ",
        "Å": "ੴ",
        "Ú": "ਃ",
        "Ç": "☬",
        "@": "ੑ",
        "‚": "❁",
        "•": "੶",
        " ": " ",
    ]

    /// Pre-pass: each entry's reverse appears in some Anmol Lipi sources
    /// where the post-base mark was emitted before its anchor. Replace
    /// reversed-pair → canonical-pair before the per-char loop.
    static let asciiCorrections: [String] = [
        "@W", "@w", "@o", "@O", "@y", "@Y", "@ü", "@`",
        "ÍY", "Ry", "RY", "RM", "RN",
        "YN", "yN", "YM", "yM",
        "uN", "UN", "üN",
        "uM", "UM", "üM",
        "R`", "u`", "U`", "ü`",
        "Iˆ", "IN",
    ]

    /// Characters that are "half" — i.e. attach to the preceding letter.
    /// When a sihari (`i`) is followed by a consonant + half-char, the
    /// sihari moves to AFTER the half-char-bearing cluster.
    static let halfChars: Set<Character> = [
        "H", "R", "®", "Í", "ç", "†", "œ", "˜", "´", "Î", "Ï", "í", "æ",
    ]
}
