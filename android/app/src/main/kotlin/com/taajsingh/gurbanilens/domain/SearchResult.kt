package com.taajsingh.gurbanilens.domain

import com.taajsingh.gurbanilens.core.Match

/**
 * One round of voice search → matcher → top-N. Used by Results + Shabad screens.
 */
data class SearchResult(
    val transcript: String,
    val matches: List<Match>,
    val topConfidence: ConfidenceLabel,
) {
    val top: Match? get() = matches.firstOrNull()
    val alternates: List<Match> get() = matches.drop(1).take(4)

    companion object {
        fun from(transcript: String, matches: List<Match>): SearchResult {
            val label = matches.firstOrNull()
                ?.let { ConfidenceLabel.forScore(it.score) }
                ?: ConfidenceLabel.Low
            return SearchResult(transcript, matches, label)
        }
    }
}
