package com.whispercppdemo.whisper

import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Helpers used by [WhisperLib]'s static init to pick which libwhisper
 * variant (`vfpv4` / `v8fp16_va` / plain) to load based on CPU capability.
 *
 * Mirrors the WhisperUtils.java from the litongjava demo. Kept in the same
 * package so [WhisperLib]'s init block reads naturally.
 */
internal object WhisperUtils {

    fun cpuInfo(): String? = runCatching {
        BufferedReader(InputStreamReader(java.io.FileInputStream("/proc/cpuinfo"))).use { r ->
            buildString {
                var line = r.readLine()
                while (line != null) {
                    append(line).append('\n')
                    line = r.readLine()
                }
            }
        }
    }.getOrNull()
}
