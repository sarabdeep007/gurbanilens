package com.taajsingh.gurbanilens.domain

/**
 * One-shot single-buffer ASR. v1 voice-search captures a fixed-duration clip
 * (tap-to-record) and hands the whole PCM buffer to the engine — no streaming.
 *
 * Phase 1 deterministic-ASR settings (`temperature=0`, no fallback, fixed
 * seed where supported, `language="pa"`) are baked into the default
 * [Config]. Don't relax these without updating CLAUDE.md "Known Phase 2A
 * gating items" — that finding came from real Phase 1 evaluation.
 */
interface Asr {
    /**
     * Transcribe a buffer of 16 kHz mono Float32 PCM samples in [-1.0, 1.0].
     * Returns the Latin / Devanagari transcript Whisper produced — caller is
     * responsible for normalising before passing to the matcher.
     */
    suspend fun transcribe(samples: FloatArray, config: Config = Config.Default): Transcript

    /** Whether the engine is loaded and ready to transcribe. */
    val isReady: Boolean

    data class Config(
        val language: String = "pa",
        val temperature: Float = 0.0f,
        val noTemperatureFallback: Boolean = true,
        val seed: Int = 1,                // fixed seed where whisper.cpp supports it
        val maxThreads: Int = 4,
        val translate: Boolean = false,
    ) {
        companion object {
            val Default = Config()
        }
    }

    data class Transcript(
        val text: String,
        val language: String,
        val durationMs: Long,
    )
}
