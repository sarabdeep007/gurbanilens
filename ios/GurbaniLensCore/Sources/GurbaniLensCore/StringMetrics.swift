import Foundation

/// Algorithms that mirror `rapidfuzz.fuzz.ratio` and
/// `rapidfuzz.fuzz.partial_ratio`. Both use **Indel-based** edit distance
/// (insertions + deletions only — no substitutions), which is what rapidfuzz
/// defaults to and what Phase 1 matched against.
///
/// Spec lives at `core/tests/portparity/test_vectors.json#/algorithm_spec`.
public enum StringMetrics {

    // ---------------------------------------------------------------------
    // Indel distance — LCS-based
    // ---------------------------------------------------------------------

    /// Length of the longest common subsequence between `a` and `b`.
    /// Standard O(N×M) DP with rolling two-row buffer. curr[0] and prev[0]
    /// stay 0 (LCS with empty prefix is empty), so we don't bother resetting
    /// after the swap.
    @inline(__always)
    static func lcsLength(_ a: [Character], _ b: [Character]) -> Int {
        let n = a.count
        let m = b.count
        if n == 0 || m == 0 { return 0 }

        // Use UnicodeScalar-backed UInt32 arrays for fast equality comparisons
        // (Character equality goes through grapheme cluster comparison which
        // is much slower than scalar compare).
        let aScalars = a.flatMap { $0.unicodeScalars.map { $0.value } }
        let bScalars = b.flatMap { $0.unicodeScalars.map { $0.value } }
        let nn = aScalars.count
        let mm = bScalars.count
        if nn == 0 || mm == 0 { return 0 }

        var prev = [Int](repeating: 0, count: mm + 1)
        var curr = [Int](repeating: 0, count: mm + 1)
        for i in 1...nn {
            let ai = aScalars[i - 1]
            for j in 1...mm {
                if ai == bScalars[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
            // curr[0] stays 0 across iterations; no reset needed
        }
        return prev[mm]
    }

    /// Indel distance = (|a| - lcs) + (|b| - lcs) = |a| + |b| - 2 × lcs
    static func indelDistance(_ a: [Character], _ b: [Character]) -> Int {
        let lcs = lcsLength(a, b)
        return a.count + b.count - 2 * lcs
    }

    /// `fuzz.ratio` equivalent. Returns 0–100.
    /// `ratio = 100 × (len_a + len_b - indel) / (len_a + len_b)`
    public static func ratio(_ a: String, _ b: String) -> Double {
        let ac = Array(a)
        let bc = Array(b)
        return ratio(ac, bc)
    }

    static func ratio(_ a: [Character], _ b: [Character]) -> Double {
        let total = a.count + b.count
        if total == 0 { return 100.0 }
        let distance = indelDistance(a, b)
        return 100.0 * Double(total - distance) / Double(total)
    }

    // ---------------------------------------------------------------------
    // partial_ratio
    // ---------------------------------------------------------------------

    /// `fuzz.partial_ratio` equivalent. For each substring of the longer
    /// string with length = |shorter|, compute `ratio(shorter, substring)`.
    /// Return the max.
    ///
    /// rapidfuzz uses a faster O(N×M) algorithm (the "Hyyro" partial
    /// algorithm). We implement the straightforward version: brute-force
    /// over all start positions in the longer string. For matcher inputs
    /// (60K lines × short queries) this is fine; can be optimised later.
    public static func partialRatio(_ a: String, _ b: String) -> Double {
        var shorter = Array(a)
        var longer = Array(b)
        if shorter.count > longer.count {
            swap(&shorter, &longer)
        }
        let s = shorter.count
        let l = longer.count
        if s == 0 || l == 0 { return 0.0 }
        if s == l { return ratio(shorter, longer) }

        var best = 0.0
        for start in 0...(l - s) {
            let window = Array(longer[start..<(start + s)])
            let r = ratio(shorter, window)
            if r > best { best = r }
            if best >= 100.0 { break }
        }
        return best
    }
}
