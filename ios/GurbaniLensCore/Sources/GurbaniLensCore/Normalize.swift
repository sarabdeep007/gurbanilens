import Foundation

/// Canonical normalisation. Must match core/gurbanilens/matcher.py:normalize.
///
/// Rules (from `test_vectors.json#/algorithm_spec/normalize`):
///   - lowercase
///   - strip ASCII punctuation [.,;|:!?\-"'(){}\[\]0-9]+ → single space
///   - collapse whitespace
public func normalize(_ text: String) -> String {
    let lower = text.lowercased()
    var out = String()
    out.reserveCapacity(lower.count)
    var lastWasSpace = true  // suppress leading space
    for ch in lower {
        let isWordChar: Bool = {
            if ch.isASCII {
                let scalar = ch.unicodeScalars.first!.value
                // Allow lowercase a-z and non-ASCII (e.g. Gurmukhi if it ever appears)
                return (scalar >= 0x61 && scalar <= 0x7A)
            }
            // Non-ASCII letters pass through (Gurmukhi, Devanagari, etc.)
            return ch.isLetter
        }()

        if isWordChar {
            out.append(ch)
            lastWasSpace = false
        } else {
            // Treat anything else (punctuation, digits, whitespace) as separator
            if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
    }
    // Trim trailing space
    if out.last == " " { out.removeLast() }
    return out
}
