package com.taajsingh.gurbanilens.core

import org.json.JSONObject
import java.io.File
import kotlin.math.abs
import kotlin.system.exitProcess

/**
 * Standalone CLI port-parity runner. Same checks as [PortParityTest] but
 * runnable without JUnit / Gradle — used for local development validation
 * with bare `kotlinc` + `java`.
 *
 * Usage:
 *     export GURBANILENS_CORPUS_PATH=/path/to/data/sggs/database.sqlite
 *     java -cp ...:port-parity.jar com.taajsingh.gurbanilens.core.PortParityRunnerKt \
 *          android/core/src/test/resources/test_vectors.json
 *
 * Exit code 0 if all 11 cases pass; 1 otherwise.
 */
fun main(args: Array<String>) {
    val vectorsPath = args.getOrNull(0)
        ?: "android/core/src/test/resources/test_vectors.json"

    val dbPath = System.getenv("GURBANILENS_CORPUS_PATH")
        ?: error("GURBANILENS_CORPUS_PATH env var required (path to data/sggs/database.sqlite)")
    require(File(dbPath).exists()) { "Corpus DB not found at $dbPath" }

    val vectors = JSONObject(File(vectorsPath).readText())

    // Sanity-check thresholds.
    val thresholds = vectors.getJSONObject("thresholds")
    require(thresholds.getDouble("TOKEN_MATCH_THRESHOLD") == Matcher.TOKEN_MATCH_THRESHOLD)
    require(thresholds.getInt("LONG_TOKEN_MIN") == Matcher.LONG_TOKEN_MIN)
    require(thresholds.getInt("MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE") == Matcher.MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE)
    require(thresholds.getInt("CANDIDATE_POOL") == Matcher.CANDIDATE_POOL)

    println("Loading corpus from $dbPath ...")
    val t0 = System.currentTimeMillis()
    val matcher = JvmSqliteCorpus(dbPath).use { Matcher.fromCorpus(it) }
    val loadMs = System.currentTimeMillis() - t0
    println("  ${matcher.size} lines indexed in ${loadMs} ms")
    println()

    val gt = vectors.getJSONObject("ground_truth")
    val gtAng = gt.getInt("ang")
    val gtPangti = gt.getInt("pangti")

    val cases = vectors.getJSONArray("test_cases")
    var passed = 0
    var total = 0
    val failures = ArrayList<String>()

    for (i in 0 until cases.length()) {
        val tc = cases.getJSONObject(i)
        val label = tc.getString("label")
        val query = tc.getString("query")
        val category = tc.getString("category")
        val canonical = tc.getJSONObject("python_canonical")
        val assertions = tc.getJSONObject("assertions")
        total++

        val tStart = System.currentTimeMillis()
        val results = matcher.match(query, topN = 3)
        val tElapsed = System.currentTimeMillis() - tStart

        val caseFailures = ArrayList<String>()

        if (results.isEmpty()) {
            caseFailures.add("no results")
        } else {
            val top = results.first()

            val pyScore = canonical.optDouble("top_score", Double.NaN)
            if (!pyScore.isNaN() && abs(top.score - pyScore) > 2.0) {
                caseFailures.add(
                    "score drift Kotlin=${"%.2f".format(top.score)} vs Python=${"%.2f".format(pyScore)} (Δ>2.0)"
                )
            }

            if (category == "good") {
                if (top.line.ang != gtAng || top.line.pangti != gtPangti) {
                    caseFailures.add(
                        "top Ang ${top.line.ang}:P${top.line.pangti}, expected Ang $gtAng:P$gtPangti"
                    )
                }
                val good = assertions.optJSONObject("good")
                if (good != null) {
                    val minScore = good.getDouble("score_at_least")
                    if (top.score < minScore) {
                        caseFailures.add("score ${"%.1f".format(top.score)} < expected_at_least $minScore")
                    }
                }
            } else { // bad
                for (r in results) {
                    if (r.line.ang == gtAng && r.line.pangti == gtPangti) {
                        caseFailures.add("ground truth in top-3 at score ${"%.1f".format(r.score)}")
                    }
                }
                val bad = assertions.optJSONObject("bad")
                if (bad != null) {
                    val maxScore = bad.getDouble("score_at_most")
                    if (top.score > maxScore) {
                        caseFailures.add("top score ${"%.1f".format(top.score)} > expected_at_most $maxScore")
                    }
                }
            }
        }

        val verdict = if (caseFailures.isEmpty()) {
            passed++
            "PASS"
        } else "FAIL"

        val top = results.firstOrNull()
        val topStr = if (top != null) {
            "Ang ${top.line.ang}:P${top.line.pangti ?: "-"}  score=${"%6.2f".format(top.score)}"
        } else "no results"
        println("  [${verdict}] ${label.padEnd(56)}  ${topStr}  (${tElapsed} ms)")
        if (caseFailures.isNotEmpty()) {
            for (f in caseFailures) println("           ↳ $f")
            failures.add("$label: ${caseFailures.joinToString("; ")}")
        }
    }

    println()
    println("Port parity: $passed / $total PASS")
    if (failures.isNotEmpty()) {
        println()
        println("FAILURES:")
        for (f in failures) println("  - $f")
        exitProcess(1)
    }
}
