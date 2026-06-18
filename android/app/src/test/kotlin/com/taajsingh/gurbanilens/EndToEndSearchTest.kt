package com.taajsingh.gurbanilens

import com.taajsingh.gurbanilens.audio.AudioRecorder
import com.taajsingh.gurbanilens.core.Line
import com.taajsingh.gurbanilens.core.Matcher
import com.taajsingh.gurbanilens.domain.ConfidenceLabel
import com.taajsingh.gurbanilens.domain.MockAsr
import com.taajsingh.gurbanilens.domain.VoiceSearchSession
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * End-to-end smoke test for the v1 voice-search pipeline. Walks the same
 * code path the UI walks, just substituting:
 *
 *   - real microphone capture → [AudioRecorder.syntheticTone] (deterministic PCM)
 *   - real whisper.cpp ASR    → [MockAsr] returning a canned transcript
 *   - bundled corpus          → small in-memory `List<Line>` (matcher tested in
 *                                its full 11/11 port-parity battery already)
 *
 * What this test proves: the [VoiceSearchSession.runSearch] orchestration
 * threads samples → ASR → matcher → SearchResult correctly, surfaces the
 * right [ConfidenceLabel] band, and the wiring shape lines up with
 * MainActivity's call site. The matcher's *correctness* against canonical
 * Python is covered by `core/src/test/.../PortParityTest`.
 */
class EndToEndSearchTest {

    private val sampleLines = listOf(
        line("L1", "CWK", 462, 3, "meenaa jalaheen meenaa jalaheen he"),
        line("L2", "ABC", 100, 1, "har ki bhagati saara"),
        line("L3", "DEF", 200, 5, "naam japat te kade na haare"),
        line("L4", "GHI", 300, 2, "ik onkar sat naam karataa purakh"),
        line("L5", "JKL", 400, 4, "ang sang baahir na hor saath"),
    )

    @Test
    fun fullPipeline_synthesisedAudio_mockAsr_findsExpectedMatch() = runTest {
        val matcher = Matcher.fromLines(sampleLines)
        val session = VoiceSearchSession()
        val asr = MockAsr(canned = "meenaa jalaheen meenaa jalaheen he")
        val samples = AudioRecorder.syntheticTone(durationMs = 1_000)

        val result = session.runSearch(
            samples = samples,
            asr = asr,
            matcher = matcher,
        )

        // Top match should be the line we canned the transcript for.
        assertNotNull("expected a top match", result.top)
        val top = result.top!!
        assertEquals(462, top.line.ang)
        assertEquals(3, top.line.pangti)
        assertEquals("CWK", top.line.shabadId)

        // Score should be high — exact match on the same string.
        assertTrue("expected ≥ 95.0, got ${top.score}", top.score >= 95.0)
        assertEquals(ConfidenceLabel.Strong, result.topConfidence)

        // Session state should have flipped to Done with our result.
        val state = session.state.value
        assertTrue("state $state was not Done", state is VoiceSearchSession.State.Done)
        assertEquals(result, (state as VoiceSearchSession.State.Done).result)
    }

    @Test
    fun fullPipeline_unrelatedTranscript_lowConfidence() = runTest {
        val matcher = Matcher.fromLines(sampleLines)
        val session = VoiceSearchSession()
        val asr = MockAsr(canned = "the quick brown fox jumps over the lazy dog")

        val result = session.runSearch(
            samples = AudioRecorder.syntheticTone(durationMs = 500),
            asr = asr,
            matcher = matcher,
        )

        // For a fully unrelated query, the matcher's length-factor + token
        // coverage should keep the top score very low.
        val top = result.top
        assertNotNull(top)
        assertTrue(
            "expected score < ${Matcher.MATCH_THRESHOLD}, got ${top!!.score}",
            top.score < Matcher.MATCH_THRESHOLD,
        )
        assertTrue(
            "expected Low or Possible label, got ${result.topConfidence}",
            result.topConfidence != ConfidenceLabel.Strong,
        )
    }

    @Test
    fun fullPipeline_emptyTranscript_returnsEmptyMatches() = runTest {
        val matcher = Matcher.fromLines(sampleLines)
        val session = VoiceSearchSession()
        val asr = MockAsr(canned = "")

        val result = session.runSearch(
            samples = AudioRecorder.syntheticTone(durationMs = 100),
            asr = asr,
            matcher = matcher,
        )

        assertEquals("", result.transcript)
        assertTrue("matches should be empty", result.matches.isEmpty())
        assertEquals(ConfidenceLabel.Low, result.topConfidence)
    }

    private fun line(id: String, shabadId: String, ang: Int, pangti: Int, translit: String) =
        Line(
            id = id,
            shabadId = shabadId,
            ang = ang,
            pangti = pangti,
            lineType = "Pankti",
            gurmukhi = translit,                     // not under test here
            gurmukhiUnicode = null,
            transliterationEn = translit,
            firstLetters = null,
            orderId = id.hashCode(),
        )
}
