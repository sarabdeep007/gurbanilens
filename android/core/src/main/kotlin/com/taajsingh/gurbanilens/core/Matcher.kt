package com.taajsingh.gurbanilens.core

/**
 * Fuzzy Pankti matcher. Kotlin port of `core/gurbanilens/matcher.py:Matcher`.
 *
 * Validated against `core/tests/portparity/test_vectors.json`. See
 * [com.taajsingh.gurbanilens.core.PortParityTest][PortParityTest] for the
 * battery; identical results to Python (within ±2 points on score) are a
 * port-parity requirement.
 *
 * Algorithm
 * ---------
 *  Stage 1 (recall):    fuzz.partial_ratio(query, line) — take top CANDIDATE_POOL
 *  Stage 2 (precision): per candidate, compute token_coverage:
 *      for each query "long token" (≥ LONG_TOKEN_MIN chars),
 *      max fuzz.ratio over candidate tokens; count covered if ≥ TOKEN_MATCH_THRESHOLD
 *  Length factor:       min(1, n_long_query_tokens / MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE)
 *  Final coverage:      (covered / n_long_query_tokens) × length_factor
 *  Final score:         partial_ratio × final_coverage      (0..100 scale)
 *
 * The length factor is the critical safety property: a 1-token Whisper-on-silence
 * hallucination ("nan", "at six") can no longer trivially achieve 100% coverage and
 * therefore can't produce a high-confidence false match. Phase 1 finding.
 */
class Matcher private constructor(
    val lines: List<Line>,
    internal val normalizedTexts: List<String>,
    internal val tokens: List<List<String>>,
) {
    val size: Int get() = lines.size

    fun match(query: String, topN: Int = 5): List<Match> {
        val normalised = normalize(query)
        if (normalised.isEmpty()) return emptyList()
        val qLong = longTokens(normalised)

        // Stage 1: rank every line by partial_ratio, take top CANDIDATE_POOL.
        // For the 60K-line SGGS this is the hot path; brute force is fine for
        // single-shot v1 voice search, will need Hyyro/n-gram for v2 continuous.
        val stage1 = ArrayList<Pair<Double, Int>>(normalizedTexts.size)
        for (i in normalizedTexts.indices) {
            val pr = StringMetrics.partialRatio(normalised, normalizedTexts[i])
            stage1.add(pr to i)
        }
        stage1.sortByDescending { it.first }
        val pool = stage1.subList(0, minOf(CANDIDATE_POOL, stage1.size))

        // Stage 2: re-rank by partial_ratio × token_coverage.
        data class Scored(
            val score: Double,
            val partial: Double,
            val coverage: Double,
            val index: Int,
        )
        val rescored = ArrayList<Scored>(pool.size)
        for ((partial, index) in pool) {
            val cov = tokenCoverage(qLong, tokens[index])
            val final = partial * cov
            rescored.add(Scored(final, partial, cov, index))
        }
        rescored.sortByDescending { it.score }

        val take = minOf(topN, rescored.size)
        val out = ArrayList<Match>(take)
        for (i in 0 until take) {
            val s = rescored[i]
            out.add(
                Match(
                    line = lines[s.index],
                    score = s.score,
                    partialRatio = s.partial,
                    coverage = s.coverage,
                )
            )
        }
        return out
    }

    // -----------------------------------------------------------------

    internal fun longTokens(normalised: String): List<String> =
        normalised.split(' ').filter { it.length >= LONG_TOKEN_MIN }

    internal fun tokenCoverage(queryLongTokens: List<String>, candidateTokens: List<String>): Double {
        if (queryLongTokens.isEmpty() || candidateTokens.isEmpty()) return 0.0

        var matched = 0
        for (qt in queryLongTokens) {
            var best = 0.0
            for (ct in candidateTokens) {
                val r = StringMetrics.ratio(qt, ct)
                if (r > best) best = r
                if (best >= 100.0) break
            }
            if (best >= TOKEN_MATCH_THRESHOLD) matched++
        }
        val raw = matched.toDouble() / queryLongTokens.size
        val lengthFactor = minOf(
            1.0,
            queryLongTokens.size.toDouble() / MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE
        )
        return raw * lengthFactor
    }

    companion object {
        // Thresholds — must match `test_vectors.json#/thresholds`.
        const val TOKEN_MATCH_THRESHOLD: Double = 55.0
        const val LONG_TOKEN_MIN: Int = 3
        const val MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE: Int = 4
        const val CANDIDATE_POOL: Int = 50
        const val MATCH_THRESHOLD: Double = 75.0

        fun fromLines(lines: Iterable<Line>): Matcher {
            val ls = ArrayList<Line>()
            val nt = ArrayList<String>()
            val ts = ArrayList<List<String>>()
            for (line in lines) {
                val t = line.transliterationEn ?: continue
                val normalised = normalize(t)
                if (normalised.isEmpty()) continue
                ls.add(line)
                nt.add(normalised)
                ts.add(normalised.split(' '))
            }
            return Matcher(ls, nt, ts)
        }

        fun fromCorpus(corpus: Corpus): Matcher = fromLines(corpus.allLines().asIterable())
    }
}
