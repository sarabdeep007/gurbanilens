package com.taajsingh.gurbanilens.domain

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the domain [Asr] surface — covers [MockAsr] behaviour
 * and the [Asr.Config] defaults that document Phase 1 ASR settings.
 *
 * [WhisperAsr] itself is not unit-testable on the host JVM (requires the
 * native libwhisper.so + a model bundled in Android assets). It's
 * covered by an end-to-end smoke run on emulator or device — see
 * `STATUS.md` "What's In Flight".
 */
class AsrTest {

    @Test
    fun mockAsr_returnsCannedTranscript() = runTest {
        val asr = MockAsr(canned = "ik onkar sat naam")
        val out = asr.transcribe(FloatArray(16_000))
        assertEquals("ik onkar sat naam", out.text)
        assertEquals("pa", out.language)
        assertEquals(1_000L, out.durationMs)   // 16000 samples / 16kHz × 1000 ms
    }

    @Test
    fun config_defaultsMatchPhase1Settings() {
        val c = Asr.Config.Default
        assertEquals("pa", c.language)
        assertEquals(0.0f, c.temperature, 1e-6f)
        assertTrue("Phase 1 finding: disable temperature fallback", c.noTemperatureFallback)
        assertEquals(1, c.seed)
        assertEquals(false, c.translate)
    }

    @Test
    fun mockAsr_alwaysReady() {
        val asr = MockAsr(canned = "")
        assertTrue(asr.isReady)
    }
}
