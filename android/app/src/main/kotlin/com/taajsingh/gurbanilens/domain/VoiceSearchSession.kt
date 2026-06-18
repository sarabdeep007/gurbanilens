package com.taajsingh.gurbanilens.domain

import com.taajsingh.gurbanilens.core.Matcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Cross-screen state for one voice-search round-trip. Held by MainActivity
 * (activity-scoped) and read by the Compose nav graph. Plain Kotlin —
 * no DI, no Hilt, no ViewModel framework for v1.
 *
 * Phases:
 *   Idle        — Home screen, awaiting tap
 *   Recording   — mic capture in progress; live peak amplitude
 *   Transcribing— Whisper running
 *   Done        — SearchResult ready; Results screen rendering
 *   Error       — message surfaced to UI
 */
class VoiceSearchSession {

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    fun setRecording(peak: Float = 0f) {
        _state.value = State.Recording(peak)
    }

    fun setTranscribing() {
        _state.value = State.Transcribing
    }

    fun setDone(result: SearchResult) {
        _state.value = State.Done(result)
    }

    fun setError(msg: String) {
        _state.value = State.Error(msg)
    }

    fun reset() {
        _state.value = State.Idle
    }

    sealed interface State {
        data object Idle : State
        data class Recording(val peak: Float) : State
        data object Transcribing : State
        data class Done(val result: SearchResult) : State
        data class Error(val msg: String) : State
    }

    /**
     * End-to-end: capture is the caller's job; we take the captured samples,
     * run them through [asr], normalise (just trim — the matcher does its own
     * normalisation), and hand to [matcher]. Returns [SearchResult] OR throws.
     */
    suspend fun runSearch(
        samples: FloatArray,
        asr: Asr,
        matcher: Matcher,
        config: Asr.Config = Asr.Config.Default,
    ): SearchResult {
        setTranscribing()
        val transcript = asr.transcribe(samples, config)
        val raw = transcript.text.trim()
        val matches = if (raw.isEmpty()) emptyList() else matcher.match(raw, topN = 5)
        val result = SearchResult.from(transcript = raw, matches = matches)
        setDone(result)
        return result
    }
}
