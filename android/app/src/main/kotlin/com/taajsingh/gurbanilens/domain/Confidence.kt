package com.taajsingh.gurbanilens.domain

import com.taajsingh.gurbanilens.core.Matcher

/**
 * v1 surfaces user-facing labels, never raw matcher scores. Bands derived
 * from Phase 1 thresholds (`MATCH_THRESHOLD = 75`, `TOKEN_MATCH_THRESHOLD = 55`).
 */
enum class ConfidenceLabel(val display: String) {
    Strong("Strong match"),
    Possible("Possible match"),
    Low("Low confidence"),
    ;

    companion object {
        fun forScore(score: Double): ConfidenceLabel = when {
            score >= Matcher.MATCH_THRESHOLD -> Strong   // 75+
            score >= 50.0 -> Possible
            else -> Low
        }
    }
}
