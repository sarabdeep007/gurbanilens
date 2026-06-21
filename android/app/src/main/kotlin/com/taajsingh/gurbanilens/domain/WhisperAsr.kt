package com.taajsingh.gurbanilens.domain

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import com.whispercppdemo.whisper.WhisperLib
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream

/**
 * whisper.cpp-backed [Asr] implementation.
 *
 * Loads a `ggml-*.bin` model from the bundled assets the first time
 * [transcribe] is called and keeps the C++ context alive for the lifetime
 * of this Kotlin instance. Call [close] (or rely on JVM finalisation in
 * tests) to free the native context.
 *
 * Threading
 * ---------
 * `WhisperLib.fullTranscribe` is a blocking C call. We dispatch onto
 * [Dispatchers.Default] so the call doesn't block the UI thread. The native
 * side uses `n_threads` worker threads internally — see [Asr.Config.maxThreads].
 *
 * Phase 1 ASR config compliance
 * -----------------------------
 *  - temperature=0           ✓ (whisper.cpp greedy defaults)
 *  - no temperature fallback ✓ (greedy defaults)
 *  - fixed seed              ⚠ NOT exposed via this prebuilt .so JNI
 *  - language="pa"           ⚠ hardcoded to "en" in this prebuilt .so JNI
 *
 * The two ⚠ items are deferred to a follow-up commit that vendors
 * whisper.cpp source + builds via NDK (when we want full Phase 1 config
 * control). Documented in STATUS.md "What's In Flight".
 */
@RequiresApi(Build.VERSION_CODES.O)
class WhisperAsr private constructor(
    private val contextPtr: Long,
    private val modelDescription: String,
) : Asr, AutoCloseable {

    @Volatile private var closed: Boolean = false

    override val isReady: Boolean get() = !closed && contextPtr != 0L

    override suspend fun transcribe(samples: FloatArray, config: Asr.Config): Asr.Transcript =
        withContext(Dispatchers.Default) {
            check(!closed) { "WhisperAsr already closed" }
            val started = System.currentTimeMillis()
            WhisperLib.fullTranscribe(contextPtr, config.maxThreads, samples)
            val n = WhisperLib.getTextSegmentCount(contextPtr)
            val sb = StringBuilder()
            for (i in 0 until n) {
                sb.append(WhisperLib.getTextSegment(contextPtr, i))
            }
            val elapsed = System.currentTimeMillis() - started
            Asr.Transcript(
                text = sb.toString().trim(),
                language = "en",     // hardcoded by current prebuilt JNI; see class kdoc
                durationMs = elapsed,
            )
        }

    override fun close() {
        if (closed) return
        closed = true
        runCatching { WhisperLib.freeContext(contextPtr) }
            .onFailure { Log.w(TAG, "freeContext threw", it) }
    }

    companion object {
        private const val TAG = "WhisperAsr"

        /**
         * Default bundled model filename in `app/src/main/assets/`.
         *
         * Multilingual `ggml-base.bin` (~148 MB). The previous bundled
         * `ggml-tiny.en.bin` was English-only and couldn't transcribe
         * Punjabi — the multilingual base model is the smallest one that
         * actually handles Punjabi input. The .so still passes
         * `language="en"`; with a multilingual model that yields a
         * Punjabi → English-Latin phonetic transcript, which is exactly
         * the matcher's input format.
         *
         * Populated by `scripts/fetch_android_deps.sh`.
         */
        const val DEFAULT_MODEL_ASSET: String = "ggml-base.bin"

        /**
         * Build a [WhisperAsr] backed by a `ggml-*.bin` model bundled in
         * `assets/`. Returns `null` if the JNI couldn't load (model missing,
         * .so not loaded, context init failed) — caller should fall back
         * to [MockAsr].
         */
        suspend fun fromAssetOrNull(
            ctx: Context,
            assetName: String = DEFAULT_MODEL_ASSET,
        ): WhisperAsr? = withContext(Dispatchers.IO) {
            try {
                val ptr = WhisperLib.initContextFromAsset(ctx.assets, assetName)
                if (ptr == 0L) {
                    Log.w(TAG, "initContextFromAsset returned NULL for '$assetName'")
                    null
                } else {
                    WhisperAsr(ptr, assetName)
                }
            } catch (e: UnsatisfiedLinkError) {
                Log.w(TAG, "Whisper native lib unavailable", e)
                null
            } catch (t: Throwable) {
                Log.w(TAG, "WhisperAsr init failed", t)
                null
            }
        }

        /**
         * Build from a file on disk (e.g. user-downloaded `medium` upgrade
         * in the app's files dir). Same null-on-failure semantics.
         */
        suspend fun fromFileOrNull(modelPath: String): WhisperAsr? =
            withContext(Dispatchers.IO) {
                try {
                    val ptr = WhisperLib.initContext(modelPath)
                    if (ptr == 0L) null else WhisperAsr(ptr, File(modelPath).name)
                } catch (t: Throwable) {
                    Log.w(TAG, "WhisperAsr file-init failed", t)
                    null
                }
            }
    }
}
