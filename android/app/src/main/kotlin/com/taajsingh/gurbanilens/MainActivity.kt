package com.taajsingh.gurbanilens

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.taajsingh.gurbanilens.audio.AudioRecorder
import com.taajsingh.gurbanilens.audio.RecordingEvent
import com.taajsingh.gurbanilens.audio.recordWithMeter
import com.taajsingh.gurbanilens.core.Line
import com.taajsingh.gurbanilens.core.Matcher
import com.taajsingh.gurbanilens.data.AndroidAssetCorpus
import com.taajsingh.gurbanilens.domain.Asr
import com.taajsingh.gurbanilens.domain.MockAsr
import com.taajsingh.gurbanilens.domain.VoiceSearchSession
import com.taajsingh.gurbanilens.domain.WhisperAsr
import com.taajsingh.gurbanilens.ui.AppNavGraph
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * v1 entry point. Owns the [VoiceSearchSession], the [AudioRecorder], the
 * [Matcher] (built once from the bundled corpus) and the [Asr] engine —
 * passes everything down to the Compose nav graph via callbacks.
 *
 * State machine summary:
 *
 *   Idle ──tap──► Recording ──stopSignal──► Transcribing ──asr done──► Done
 *                    │                                                    │
 *                    └── cancel ───────────────────────────────────► Idle
 */
class MainActivity : ComponentActivity() {

    private val session = VoiceSearchSession()
    private val audioRecorder = AudioRecorder()

    @Volatile private var stopRequested: Boolean = false
    private var captureJob: Job? = null

    // Lazy — built on first use because the corpus copy + matcher build is
    // ~5–10 s and we don't want to block app launch.
    private var matcher: Matcher? = null
    private var corpus: AndroidAssetCorpus? = null

    // Warmup the JNI Whisper context off the main thread the moment the
    // activity is created so the user's first mic tap doesn't pay a 3-5 s
    // cold-start tax. `fromAssetOrNull` returns null if either the bundled
    // ggml-*.bin asset is missing or libwhisper.so failed to load — fall
    // back to an empty-canned MockAsr so the app still launches cleanly
    // and the UI surfaces "no matches" instead of crashing.
    private val asrDeferred: Deferred<Asr> by lazy {
        lifecycleScope.async(Dispatchers.IO) {
            WhisperAsr.fromAssetOrNull(applicationContext) ?: run {
                Log.w(TAG, "WhisperAsr unavailable; falling back to degraded MockAsr")
                MockAsr(canned = "")
            }
        }
    }

    private val micPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) startCapture()
        else session.setError("Microphone permission denied. Enable it in Settings to search by voice.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Touch `asrDeferred` to kick off the Whisper warmup in the
        // background. Result is consumed when the user taps the mic.
        asrDeferred
        setContent {
            AppNavGraph(
                session = session,
                onStartRecording = ::requestMicAndStartCapture,
                onStopRecording = { stopRequested = true },
                onCancelRecording = {
                    stopRequested = true
                    captureJob?.cancel()
                },
                fetchShabadLines = ::loadShabadLines,
            )
        }
    }

    private fun requestMicAndStartCapture() {
        val granted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) startCapture() else micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
    }

    private fun startCapture() {
        stopRequested = false
        session.setRecording(0f)
        captureJob?.cancel()
        captureJob = lifecycleScope.launch {
            try {
                val matcherInstance = ensureMatcher()
                val samples = recordFully()
                if (samples.isEmpty()) {
                    session.setError("No audio captured. Try again.")
                    return@launch
                }
                val asrInstance = asrDeferred.await()
                session.runSearch(samples = samples, asr = asrInstance, matcher = matcherInstance)
            } catch (t: Throwable) {
                Log.e(TAG, "search failed", t)
                session.setError(t.message ?: "Unknown error")
            }
        }
    }

    private suspend fun recordFully(): FloatArray {
        var captured = FloatArray(0)
        audioRecorder.recordWithMeter(stopSignal = { stopRequested }).collect { ev ->
            when (ev) {
                is RecordingEvent.Peak -> session.setRecording(ev.amplitude)
                is RecordingEvent.Done -> captured = ev.samples
            }
        }
        return captured
    }

    private suspend fun ensureMatcher(): Matcher = withContext(Dispatchers.IO) {
        matcher ?: synchronized(this@MainActivity) {
            matcher ?: run {
                // Bundled SGGS sqlite asset; build pipeline drops it at
                // app/src/main/assets/sggs.sqlite. If absent (e.g. dev
                // builds without the asset), we still scaffold a degraded
                // empty matcher rather than crashing.
                val built = try {
                    val c = AndroidAssetCorpus(applicationContext)
                    corpus = c
                    Matcher.fromCorpus(c)
                } catch (t: Throwable) {
                    Log.w(TAG, "Corpus asset missing; matcher empty", t)
                    Matcher.fromLines(emptyList())
                }
                matcher = built
                built
            }
        }
    }

    private suspend fun loadShabadLines(shabadId: String): List<Line> {
        // Stub for v1 — Corpus only has all_lines / lookup-by-ang-pangti.
        // Adding shabad_lines(shabad_id) is a 5-line addition we'll land
        // alongside the bundled-asset commit.
        return emptyList()
    }

    override fun onDestroy() {
        super.onDestroy()
        lifecycleScope.coroutineContext.cancelChildren()
        runCatching {
            // If the Whisper warmup completed before destroy, free its
            // native context. If it was still in flight, cancelChildren
            // above already cancelled the async so we have nothing to free.
            if (asrDeferred.isCompleted && !asrDeferred.isCancelled) {
                (asrDeferred.getCompleted() as? AutoCloseable)?.close()
            }
        }
        runCatching { corpus?.close() }
    }

    companion object {
        private const val TAG = "MainActivity"
    }
}
