package com.taajsingh.gurbanilens.ui

/**
 * v1 navigation routes. Plain string constants — keep nav simple until
 * the surface stabilises. Type-safe nav (Compose Navigation 2.8 routes)
 * is a deferred clean-up for v1.1.
 */
object Routes {
    const val HOME = "home"
    const val RECORDING = "recording"
    const val RESULTS = "results"
    const val SHABAD = "shabad/{shabadId}/{focusLineId}"
    const val SETTINGS = "settings"

    fun shabad(shabadId: String, focusLineId: String): String =
        "shabad/$shabadId/$focusLineId"
}
