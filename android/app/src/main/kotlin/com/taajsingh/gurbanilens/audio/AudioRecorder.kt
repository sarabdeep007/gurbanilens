package com.taajsingh.gurbanilens.audio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.coroutineContext

/**
 * Tap-to-record microphone capture for v1 voice search.
 *
 *   sample rate : 16 kHz mono  (Whisper requirement)
 *   format      : PCM 16-bit signed little-endian → normalised to Float32 [-1, 1]
 *   source      : MIC          (foreground only — no FOREGROUND_SERVICE_MICROPHONE)
 *
 * Designed for short clips (≤ 15 s). Returns the full captured PCM buffer in
 * one go from [record] — no streaming chunking. v2 will swap this for a
 * continuous AudioRecord with a ring buffer.
 *
 * On Android < API 33 we still get a working AudioRecord; runtime mic
 * permission check is the caller's job.
 */
class AudioRecorder {

    data class Config(
        val sampleRate: Int = 16_000,
        val channelConfig: Int = AudioFormat.CHANNEL_IN_MONO,
        val encoding: Int = AudioFormat.ENCODING_PCM_16BIT,
        /** Minimum capture length in milliseconds before [record] will return. */
        val minDurationMs: Long = 500,
        /** Hard upper bound — prevents runaway recordings. */
        val maxDurationMs: Long = 15_000,
    )

    /**
     * Block until [stopSignal] resolves OR the maximum duration is hit,
     * returning the captured Float32 PCM as a single buffer. Cancellation
     * of the calling coroutine releases the AudioRecord cleanly.
     */
    suspend fun record(
        config: Config = Config(),
        live: ((Float) -> Unit)? = null,
        stopSignal: suspend () -> Boolean,
    ): FloatArray {
        // Minimum buffer per Android docs — we use 4× that for safety against
        // foreground hiccups; AudioRecord still produces an exact stream so
        // the extra capacity costs nothing if unused.
        val minBuf = AudioRecord.getMinBufferSize(
            config.sampleRate,
            config.channelConfig,
            config.encoding,
        )
        require(minBuf > 0) {
            "AudioRecord.getMinBufferSize returned $minBuf — check sampleRate/channel/encoding"
        }
        val bufSize = minBuf * 4

        @Suppress("MissingPermission")  // Caller is responsible for runtime permission.
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            config.sampleRate,
            config.channelConfig,
            config.encoding,
            bufSize,
        )
        check(recorder.state == AudioRecord.STATE_INITIALIZED) {
            "AudioRecord failed to initialise — state=${recorder.state}"
        }

        val collected = ArrayList<Float>(config.sampleRate * 4)   // ~4 s headroom
        val shortBuf = ShortArray(bufSize / 2)
        val startNs = System.nanoTime()

        try {
            recorder.startRecording()

            while (coroutineContext.isActive) {
                val read = recorder.read(shortBuf, 0, shortBuf.size)
                if (read > 0) {
                    var peak = 0f
                    for (i in 0 until read) {
                        val s = shortBuf[i] / 32768.0f
                        collected.add(s)
                        val abs = if (s < 0) -s else s
                        if (abs > peak) peak = abs
                    }
                    live?.invoke(peak)
                }

                val elapsedMs = (System.nanoTime() - startNs) / 1_000_000
                if (elapsedMs >= config.maxDurationMs) break
                if (elapsedMs >= config.minDurationMs && stopSignal()) break
            }
        } finally {
            try { recorder.stop() } catch (t: Throwable) { Log.w(TAG, "stop() threw", t) }
            recorder.release()
        }

        val out = FloatArray(collected.size)
        for (i in collected.indices) out[i] = collected[i]
        return out
    }

    companion object {
        private const val TAG = "AudioRecorder"

        /**
         * Encode a Float32 PCM buffer as 16-bit little-endian PCM bytes
         * (the format whisper.cpp's `fullTranscribe` does NOT take — it
         * wants float32 directly — but useful for saving debug WAVs or
         * sending to a server fallback).
         */
        fun toPcm16Le(samples: FloatArray): ByteArray {
            val out = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (s in samples) {
                val clamped = when {
                    s > 1f -> 1f
                    s < -1f -> -1f
                    else -> s
                }
                out.putShort((clamped * 32767f).toInt().toShort())
            }
            return out.array()
        }

        /**
         * Synthesise a Float32 PCM tone (cosine sweep / fixed pitch) — useful
         * for headless tests that need a non-empty audio buffer without
         * touching a microphone.
         */
        fun syntheticTone(
            durationMs: Int = 1_000,
            sampleRate: Int = 16_000,
            frequencyHz: Double = 440.0,
            amplitude: Float = 0.3f,
        ): FloatArray {
            val n = (sampleRate * durationMs) / 1000
            val out = FloatArray(n)
            val twoPi = 2.0 * Math.PI
            for (i in 0 until n) {
                out[i] = (amplitude * Math.sin(twoPi * frequencyHz * i / sampleRate)).toFloat()
            }
            return out
        }
    }
}

/**
 * Convenience that produces a hot Flow of peak-amplitude values per buffer
 * tick (used by the RecordingScreen for the live VU bar). Wraps a single
 * [AudioRecorder.record] call.
 */
fun AudioRecorder.recordWithMeter(
    config: AudioRecorder.Config = AudioRecorder.Config(),
    stopSignal: suspend () -> Boolean,
): Flow<RecordingEvent> = callbackFlow {
    val samples = record(
        config = config,
        live = { peak -> trySend(RecordingEvent.Peak(peak)) },
        stopSignal = stopSignal,
    )
    trySend(RecordingEvent.Done(samples))
    close()
}.flowOn(Dispatchers.IO)

sealed interface RecordingEvent {
    data class Peak(val amplitude: Float) : RecordingEvent
    data class Done(val samples: FloatArray) : RecordingEvent {
        override fun equals(other: Any?): Boolean =
            other is Done && samples.contentEquals(other.samples)
        override fun hashCode(): Int = samples.contentHashCode()
    }
}
