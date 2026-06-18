package com.taajsingh.gurbanilens.domain

/**
 * Test / preview ASR — returns a fixed transcript. Lets the end-to-end
 * voice → transcript → matcher → result flow run on the JVM during
 * `:app:test` without needing libwhisper.so or a model file.
 */
class MockAsr(private val canned: String) : Asr {
    override val isReady: Boolean = true

    override suspend fun transcribe(samples: FloatArray, config: Asr.Config): Asr.Transcript =
        Asr.Transcript(
            text = canned,
            language = config.language,
            durationMs = (samples.size * 1000L) / 16000L,
        )
}
