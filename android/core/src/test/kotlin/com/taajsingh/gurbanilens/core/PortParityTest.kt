package com.taajsingh.gurbanilens.core

import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.json.JSONObject
import java.io.File
import kotlin.math.abs

/**
 * Port-parity battery. The Kotlin Matcher must satisfy every assertion in
 * `src/test/resources/test_vectors.json` (copied from
 * `core/tests/portparity/test_vectors.json`).
 *
 * The corpus SQLite is found via the `GURBANILENS_CORPUS_PATH` env var
 * (typically pointing at `data/sggs/database.sqlite` from the repo root).
 * Tests are skipped if the env var is unset or the file is missing — same
 * skip behaviour as the Swift port.
 *
 * Tolerance: ±2 points on score (matches the Swift port's tolerance) and
 * also enforces top ang/pangti equality with Python for good cases.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class PortParityTest {

    private lateinit var matcher: Matcher
    private lateinit var vectors: JSONObject
    private var corpusAvailable: Boolean = false

    @BeforeAll
    fun setUp() {
        val dbPath = System.getenv("GURBANILENS_CORPUS_PATH")
        if (dbPath.isNullOrBlank() || !File(dbPath).exists()) {
            corpusAvailable = false
            return
        }

        val jsonText = this::class.java.getResource("/test_vectors.json")?.readText()
            ?: error("test_vectors.json not found on classpath (resources/test_vectors.json)")
        vectors = JSONObject(jsonText)

        // Sanity-check that thresholds in the JSON match what the Matcher code uses.
        val thresholds = vectors.getJSONObject("thresholds")
        require(thresholds.getDouble("TOKEN_MATCH_THRESHOLD") == Matcher.TOKEN_MATCH_THRESHOLD)
        require(thresholds.getInt("LONG_TOKEN_MIN") == Matcher.LONG_TOKEN_MIN)
        require(thresholds.getInt("MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE") == Matcher.MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE)
        require(thresholds.getInt("CANDIDATE_POOL") == Matcher.CANDIDATE_POOL)

        JvmSqliteCorpus(dbPath).use { corpus ->
            matcher = Matcher.fromCorpus(corpus)
        }
        corpusAvailable = true
    }

    @Test
    fun goodAndBadCasesPassPortParity() {
        assumeTrue(corpusAvailable, "GURBANILENS_CORPUS_PATH not set or corpus missing — skipped")

        val gt = vectors.getJSONObject("ground_truth")
        val gtAng = gt.getInt("ang")
        val gtPangti = gt.getInt("pangti")

        val failures = ArrayList<String>()
        val cases = vectors.getJSONArray("test_cases")

        for (i in 0 until cases.length()) {
            val tc = cases.getJSONObject(i)
            val label = tc.getString("label")
            val query = tc.getString("query")
            val category = tc.getString("category")
            val canonical = tc.getJSONObject("python_canonical")
            val assertions = tc.getJSONObject("assertions")

            val results = matcher.match(query, topN = 3)
            if (results.isEmpty()) {
                failures.add("$label: no results")
                continue
            }
            val top = results.first()

            // Per-case parity check: top score within ±2 of Python canonical
            // (port-parity tolerance, matches Swift port).
            val pyScore = canonical.optDouble("top_score", Double.NaN)
            if (!pyScore.isNaN() && abs(top.score - pyScore) > 2.0) {
                failures.add(
                    "$label: score drift — Kotlin=${"%.2f".format(top.score)} vs Python=${"%.2f".format(pyScore)} (Δ>2.0)"
                )
            }

            if (category == "good") {
                if (top.line.ang != gtAng || top.line.pangti != gtPangti) {
                    failures.add(
                        "$label: top Ang ${top.line.ang}:P${top.line.pangti}, expected Ang $gtAng:P$gtPangti"
                    )
                }
                val good = assertions.optJSONObject("good")
                if (good != null) {
                    val minScore = good.getDouble("score_at_least")
                    if (top.score < minScore) {
                        failures.add(
                            "$label: score ${"%.1f".format(top.score)} < expected_at_least $minScore"
                        )
                    }
                }
            } else { // "bad"
                for (r in results) {
                    if (r.line.ang == gtAng && r.line.pangti == gtPangti) {
                        failures.add(
                            "$label: ground truth in top-3 at score ${"%.1f".format(r.score)}"
                        )
                    }
                }
                val bad = assertions.optJSONObject("bad")
                if (bad != null) {
                    val maxScore = bad.getDouble("score_at_most")
                    if (top.score > maxScore) {
                        failures.add(
                            "$label: top score ${"%.1f".format(top.score)} > expected_at_most $maxScore"
                        )
                    }
                }
            }
        }

        assertTrue(failures.isEmpty(), "\n  " + failures.joinToString("\n  "))
    }
}
