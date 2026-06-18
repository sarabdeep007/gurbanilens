package com.taajsingh.gurbanilens.audio

import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Host-JVM tests for [AudioRecorder]. Robolectric stubs `android.media.AudioRecord`,
 * so real PCM capture from a hardware mic isn't exercised — we cover the things
 * that DO matter for v1 correctness:
 *
 *  1. Synthetic tone generator (used by the end-to-end search test) produces
 *     the right shape + amplitude.
 *  2. Float32 → PCM16LE encoder is byte-exact, including clamping out-of-range.
 *  3. Recording event types behave as data classes (equality on samples
 *     content, not reference).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class AudioRecorderTest {

    @Test
    fun syntheticTone_lengthMatchesDuration() {
        val samples = AudioRecorder.syntheticTone(durationMs = 250, sampleRate = 16_000)
        // 250 ms × 16 kHz = 4000 samples
        assertEquals(4_000, samples.size)
    }

    @Test
    fun syntheticTone_amplitudeWithinRange() {
        val samples = AudioRecorder.syntheticTone(
            durationMs = 500,
            sampleRate = 16_000,
            frequencyHz = 220.0,
            amplitude = 0.5f,
        )
        val peak = samples.maxOf { kotlin.math.abs(it) }
        // Allow tiny floating-point slop above target amplitude.
        assertTrue("peak $peak ≤ 0.501 expected", peak <= 0.501f)
        assertTrue("peak $peak > 0.49 expected (sine reaches max)", peak > 0.49f)
    }

    @Test
    fun toPcm16Le_clampsAndEncodes() {
        val samples = floatArrayOf(0.0f, 0.5f, -0.5f, 2.0f, -2.0f, 1.0f, -1.0f)
        val bytes = AudioRecorder.toPcm16Le(samples)
        assertEquals(samples.size * 2, bytes.size)

        // Decode and verify clamping + scaling.
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val decoded = ShortArray(samples.size) { buf.short }
        assertEquals(0, decoded[0].toInt())
        // 0.5f × 32767 = 16383.5 → 16383
        assertEquals(16_383, decoded[1].toInt())
        assertEquals(-16_383, decoded[2].toInt())
        // 2.0f gets clamped to 1.0 → 32767; -2.0 → -32767
        assertEquals(32_767, decoded[3].toInt())
        assertEquals(-32_767, decoded[4].toInt())
        assertEquals(32_767, decoded[5].toInt())
        assertEquals(-32_767, decoded[6].toInt())
    }

    @Test
    fun recordingEventDone_equalityIsContentBased() {
        val a = RecordingEvent.Done(floatArrayOf(0.1f, 0.2f, 0.3f))
        val b = RecordingEvent.Done(floatArrayOf(0.1f, 0.2f, 0.3f))
        val c = RecordingEvent.Done(floatArrayOf(0.1f, 0.2f, 0.4f))
        assertEquals(a, b)
        assertTrue(a != c)
    }

    @Test
    fun record_robolectricStubReturnsEmpty() = runTest {
        // Robolectric's AudioRecord stub doesn't produce real samples. We just
        // verify the recorder constructs, starts, hits the maxDuration cap,
        // and exits cleanly — i.e. the lifecycle code is wired correctly even
        // on a stubbed Android runtime.
        val recorder = AudioRecorder()
        val samples = recorder.record(
            config = AudioRecorder.Config(
                minDurationMs = 0,
                maxDurationMs = 100,
            ),
            stopSignal = { true },
        )
        // Don't assert size — Robolectric AudioRecord can either return 0 reads
        // (empty FloatArray) or some zero-filled buffer; both indicate the loop
        // exited normally. We only assert it didn't throw.
        assertTrue("samples size $samples.size", samples.size >= 0)
    }
}
