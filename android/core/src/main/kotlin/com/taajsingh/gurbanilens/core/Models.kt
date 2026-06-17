package com.taajsingh.gurbanilens.core

/**
 * A single line of SGGS — Pankti, Rahao, Sirlekh, or Manglacharan.
 *
 * Mirrors:
 *   - core/gurbanilens/corpus.py:Line
 *   - ios/GurbaniLensCore/Sources/GurbaniLensCore/Models.swift
 */
data class Line(
    val id: String,
    val shabadId: String,
    val ang: Int,
    val pangti: Int?,
    val lineType: String?,
    val gurmukhi: String,
    val gurmukhiUnicode: String?,
    val transliterationEn: String?,
    val firstLetters: String?,
    val orderId: Int,
)

/**
 * A single match result from the [Matcher].
 *
 * Mirrors:
 *   - core/gurbanilens/matcher.py:Match
 *   - ios/GurbaniLensCore/Sources/GurbaniLensCore/Models.swift:Match
 *
 * @property score combined 0..100 (partial_ratio × coverage)
 * @property partialRatio raw partial_ratio, 0..100 (Indel-based substring match)
 * @property coverage fraction of long query tokens fuzzy-matched, 0..1
 */
data class Match(
    val line: Line,
    val score: Double,
    val partialRatio: Double,
    val coverage: Double,
)
