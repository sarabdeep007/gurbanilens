package com.taajsingh.gurbanilens.core

/**
 * Algorithms that mirror `rapidfuzz.fuzz.ratio` and `rapidfuzz.fuzz.partial_ratio`.
 *
 * Both use **Indel-based** edit distance (insertions + deletions only — no
 * substitutions), which is what rapidfuzz defaults to and what Phase 1
 * matched against.
 *
 * Spec lives at `core/tests/portparity/test_vectors.json#/algorithm_spec`.
 *
 * Implementation notes
 * --------------------
 *  - LCS is computed over Unicode code points (not Java `char` UTF-16 surrogate
 *    halves) so multi-code-point characters compare correctly. The corpus is
 *    pre-normalised to lowercase ASCII so in practice all input here is BMP,
 *    but using code points keeps the algorithm correct for any Unicode input
 *    that survives `normalize()` (e.g. diacritics in raw transliteration).
 *  - `partialRatio` is brute force — for each window of length `|shorter|`
 *    in `longer`, compute `ratio`. rapidfuzz uses Hyyro's bitmap algorithm
 *    which is asymptotically faster; brute force is correct and passes
 *    port-parity. Matches Swift port's approach.
 */
object StringMetrics {

    // ---------------------------------------------------------------------
    // Indel distance — LCS-based
    // ---------------------------------------------------------------------

    /**
     * Length of the longest common subsequence of two IntArrays of code points.
     *
     * Standard O(n×m) DP with rolling two-row buffer. `prev[0]` and `curr[0]`
     * stay 0 (LCS with empty prefix is empty) so we don't reset after swap.
     */
    internal fun lcsLength(a: IntArray, b: IntArray): Int {
        val n = a.size
        val m = b.size
        if (n == 0 || m == 0) return 0

        var prev = IntArray(m + 1)
        var curr = IntArray(m + 1)
        for (i in 1..n) {
            val ai = a[i - 1]
            for (j in 1..m) {
                curr[j] = if (ai == b[j - 1]) {
                    prev[j - 1] + 1
                } else {
                    if (prev[j] >= curr[j - 1]) prev[j] else curr[j - 1]
                }
            }
            val tmp = prev
            prev = curr
            curr = tmp
            // curr[0] stays 0 across iterations; no reset needed
        }
        return prev[m]
    }

    internal fun indelDistance(a: IntArray, b: IntArray): Int {
        val lcs = lcsLength(a, b)
        return a.size + b.size - 2 * lcs
    }

    /**
     * `fuzz.ratio` equivalent. Returns 0–100.
     *
     *   ratio = 100 × (len_a + len_b − indel) / (len_a + len_b)
     */
    fun ratio(a: String, b: String): Double {
        val ap = a.toCodePointArray()
        val bp = b.toCodePointArray()
        return ratio(ap, bp)
    }

    internal fun ratio(a: IntArray, b: IntArray): Double {
        val total = a.size + b.size
        if (total == 0) return 100.0
        val distance = indelDistance(a, b)
        return 100.0 * (total - distance) / total
    }

    // ---------------------------------------------------------------------
    // partial_ratio
    // ---------------------------------------------------------------------

    /**
     * `fuzz.partial_ratio` equivalent. For each substring of the longer
     * string with length = |shorter|, compute `ratio(shorter, substring)`.
     * Return the max.
     */
    fun partialRatio(a: String, b: String): Double {
        val ap = a.toCodePointArray()
        val bp = b.toCodePointArray()
        var shorter: IntArray
        var longer: IntArray
        if (ap.size > bp.size) {
            longer = ap; shorter = bp
        } else {
            longer = bp; shorter = ap
        }
        val s = shorter.size
        val l = longer.size
        if (s == 0 || l == 0) return 0.0
        if (s == l) return ratio(shorter, longer)

        var best = 0.0
        val window = IntArray(s)
        for (start in 0..(l - s)) {
            System.arraycopy(longer, start, window, 0, s)
            val r = ratio(shorter, window)
            if (r > best) best = r
            if (best >= 100.0) break
        }
        return best
    }
}

/**
 * Decompose a Kotlin/JVM `String` into its Unicode code points, returning an
 * IntArray. Avoids the trap where high-plane characters become surrogate-pair
 * `char` values that compare as separate units in `String.toCharArray()`.
 */
internal fun String.toCodePointArray(): IntArray {
    // For pure-BMP strings (the common case after normalize), this is just
    // `length`-many code points. For supplementary-plane strings, fewer.
    val cpCount = this.codePointCount(0, this.length)
    val out = IntArray(cpCount)
    var idx = 0
    var i = 0
    while (i < this.length) {
        val cp = this.codePointAt(i)
        out[idx++] = cp
        i += Character.charCount(cp)
    }
    return out
}
