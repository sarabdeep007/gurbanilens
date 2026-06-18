@file:JvmName("WhisperLib")
package com.whispercppdemo.whisper

import android.content.res.AssetManager
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import java.io.InputStream

/**
 * Thin Kotlin port of `com.whispercppdemo.whisper.WhisperLib` from the
 * litongjava whisper.cpp.android.java.demo project — kept in this exact
 * package + class layout because the prebuilt libwhisper.so files we vendor
 * at `app/src/main/jniLibs/<arch>/libwhisper*.so` export their JNI symbols
 * under that name:
 *
 *   Java_com_whispercppdemo_whisper_WhisperLib_fullTranscribe
 *
 * Don't rename the package or the class — the runtime dynamic linker matches
 * symbol names to the fully-qualified Java/Kotlin class path.
 *
 * Idiomatic Kotlin wrappers live in [com.taajsingh.gurbanilens.domain.WhisperAsr].
 *
 * Phase 1 ASR config note
 * -----------------------
 * The prebuilt .so files hardcode `language = "en"` and use whisper.cpp's
 * `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)` defaults (which
 * include `temperature = 0.0f`, no temperature fallback, and greedy
 * sampling). That covers two of the four Phase 1 settings (greedy ✓,
 * temperature=0 ✓); language defaults to `"en"` (deviation — Phase 1 finding
 * was `language="pa"`) and seed is not exposed via JNI (deviation).
 *
 * **Why the language=en deviation is acceptable for v1:** Whisper-en
 * transcribes Punjabi recitation phonetically into English-Latin, which is
 * the matcher's native input format. Phase 1 used `language="pa"` which
 * outputs Devanagari and required a to_latin pipeline. With "en" we skip
 * to_latin entirely. STATUS.md notes this as a known deviation; we'll
 * revisit when we move off prebuilt .so to NDK-compiled source.
 */
@RequiresApi(api = Build.VERSION_CODES.O)
object WhisperLib {
    private const val LOG_TAG = "LibWhisper"

    init {
        Log.d(LOG_TAG, "Primary ABI: " + Build.SUPPORTED_ABIS[0])
        val primary = Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
        val cpuInfo = runCatching { WhisperUtils.cpuInfo() }.getOrNull()
        val loadVfpv4 = primary == "armeabi-v7a" && cpuInfo?.contains("vfpv4") == true
        val loadV8fp16 = primary == "arm64-v8a" && cpuInfo?.contains("fphp") == true

        try {
            when {
                loadVfpv4 -> {
                    Log.d(LOG_TAG, "Loading libwhisper_vfpv4.so")
                    System.loadLibrary("whisper_vfpv4")
                }
                loadV8fp16 -> {
                    Log.d(LOG_TAG, "Loading libwhisper_v8fp16_va.so")
                    System.loadLibrary("whisper_v8fp16_va")
                }
                else -> {
                    Log.d(LOG_TAG, "Loading libwhisper.so")
                    System.loadLibrary("whisper")
                }
            }
        } catch (t: UnsatisfiedLinkError) {
            // The .so files aren't vendored in pure-JVM unit tests (Robolectric
            // host) — failing here would mean any test that touches this class
            // crashes at class-init. We catch + log so [WhisperAsr.isReady]
            // can flip false and tests can fall back to [MockAsr].
            Log.w(LOG_TAG, "libwhisper not loaded — running without JNI", t)
        }
    }

    @JvmStatic external fun initContextFromInputStream(inputStream: InputStream): Long
    @JvmStatic external fun initContextFromAsset(assetManager: AssetManager, assetPath: String): Long
    @JvmStatic external fun initContext(modelPath: String): Long
    @JvmStatic external fun freeContext(contextPtr: Long)
    @JvmStatic external fun fullTranscribe(contextPtr: Long, numThreads: Int, audioData: FloatArray)
    @JvmStatic external fun getTextSegmentCount(contextPtr: Long): Int
    @JvmStatic external fun getTextSegment(contextPtr: Long, index: Int): String
    @JvmStatic external fun getTextSegmentT0(contextPtr: Long, index: Int): Long
    @JvmStatic external fun getTextSegmentT1(contextPtr: Long, index: Int): Long
    @JvmStatic external fun getSystemInfo(): String
    @JvmStatic external fun benchMemcpy(nthread: Int): String
    @JvmStatic external fun benchGgmlMulMat(nthread: Int): String
}
