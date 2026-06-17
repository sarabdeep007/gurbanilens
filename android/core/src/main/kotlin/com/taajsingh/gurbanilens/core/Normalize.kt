package com.taajsingh.gurbanilens.core

/**
 * Canonical normalisation. Must match `core/gurbanilens/matcher.py:normalize`.
 *
 * Rules (from `test_vectors.json#/algorithm_spec/normalize`):
 *   - lowercase
 *   - strip ASCII punctuation `[.,;|:!?\-"'(){}\[\]0-9]+` → single space
 *   - collapse whitespace
 */

private val PUNCT_RE = Regex("[.,;|:!?\\-\"'(){}\\[\\]0-9]+")
private val WS_RE = Regex("\\s+")

fun normalize(text: String): String {
    var s = text.lowercase()
    s = PUNCT_RE.replace(s, " ")
    s = WS_RE.replace(s, " ")
    return s.trim()
}
