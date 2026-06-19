import Foundation
import SwiftUI
import GurbaniLensCore

/// Cross-screen state for one voice-search round-trip. Held by ``AppContainer``
/// (app-scoped) and observed by the nav graph. Mirrors
/// `android/.../domain/VoiceSearchSession.kt`.
///
/// Phases:
///   - ``idle``         — Home screen, awaiting tap
///   - ``recording``    — mic capture in progress; live peak amplitude
///   - ``transcribing`` — Whisper running
///   - ``done``         — ``SearchResult`` ready
///   - ``error``        — message surfaced to UI
@MainActor
public final class VoiceSearchSession: ObservableObject {

    public enum State: Equatable {
        case idle
        case recording(peak: Float)
        case transcribing
        case done(SearchResult)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.transcribing, .transcribing): return true
            case (.recording(let a), .recording(let b)): return a == b
            case (.done(let a), .done(let b)):
                return a.transcript == b.transcript && a.matches.map(\.line.id) == b.matches.map(\.line.id)
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published public private(set) var state: State = .idle

    public init() {}

    public func setRecording(peak: Float = 0) { state = .recording(peak: peak) }
    public func setTranscribing() { state = .transcribing }
    public func setDone(_ result: SearchResult) { state = .done(result) }
    public func setError(_ msg: String) { state = .error(msg) }
    public func reset() { state = .idle }

    public var doneResult: SearchResult? {
        if case .done(let r) = state { return r } else { return nil }
    }

    public var errorMessage: String? {
        if case .error(let m) = state { return m } else { return nil }
    }

    public var recordingPeak: Float {
        if case .recording(let p) = state { return p } else { return 0 }
    }

    /// End-to-end search. Caller has captured `samples`; we hand them to
    /// `asr`, normalise (`matcher` runs its own normalisation pass), and
    /// query `matcher`. Throws ⇒ caller surfaces an error state.
    public func runSearch(
        samples: [Float],
        asr: Asr,
        matcher: Matcher,
        config: AsrConfig = .default
    ) async throws -> SearchResult {
        setTranscribing()
        let transcript = try await asr.transcribe(samples, config: config)
        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = raw.isEmpty ? [] : matcher.match(raw, topN: 5)
        let result = SearchResult.from(transcript: raw, matches: matches)
        setDone(result)
        return result
    }
}
