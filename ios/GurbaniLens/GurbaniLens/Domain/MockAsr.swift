import Foundation

/// Returns a fixed transcript. Used in SwiftUI previews and as the bring-up
/// fallback when the bundled Whisper model is missing — so the UI can be
/// exercised without a working JNI/C++ path.
///
/// Mirrors `android/.../domain/MockAsr.kt`.
public final class MockAsr: Asr {
    private let canned: String
    private let simulatedMs: Int64

    public init(canned: String = "ik oankaar sat naam karataa purakh", simulatedMs: Int64 = 250) {
        self.canned = canned
        self.simulatedMs = simulatedMs
    }

    public var isReady: Bool { true }

    public func transcribe(_ samples: [Float], config: AsrConfig) async throws -> AsrTranscript {
        // Tiny synthetic delay so the Transcribing state actually paints.
        try? await Task.sleep(nanoseconds: UInt64(simulatedMs) * 1_000_000)
        // gurmukhi="" — MockAsr's canned text is already Latin; the v1
        // display path falls back to `text` when gurmukhi is empty.
        return AsrTranscript(text: canned, gurmukhi: "", language: config.language, durationMs: simulatedMs)
    }
}
