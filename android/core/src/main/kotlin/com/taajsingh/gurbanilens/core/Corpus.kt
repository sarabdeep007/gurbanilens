package com.taajsingh.gurbanilens.core

/**
 * Read-only SGGS corpus. Implementations:
 *   - JVM tests:   `JvmSqliteCorpus` (xerial sqlite-jdbc, in test source set)
 *   - Android app: `AndroidAssetCorpus` (android.database.sqlite, in :app module)
 *
 * Mirrors `core/gurbanilens/corpus.py:Corpus`.
 */
interface Corpus {
    /** Every SGGS line that has English transliteration, in canonical order. */
    fun allLines(): Sequence<Line>

    /** Lookup by Ang (source_page) + Pankti (source_line). */
    fun lookup(ang: Int, pangti: Int): List<Line>
}
