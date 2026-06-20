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
///   - ``done``         — ``SearchResult`` ready (possibly empty)
///   - ``error``        — message surfaced to UI
///
/// Every setter logs `[DIAG]` so we can correlate UI symptoms (e.g. "stuck
/// on Transcribing") with the actual state machine via the Xcode console.
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

    public func setRecording(peak: Float = 0) {
        // Don't NSLog every peak — too noisy. Only the transition into
        // recording is interesting. (peak=0 means startRecording fired.)
        if case .recording = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → recording (initial peak=\(peak))")
        }
        state = .recording(peak: peak)
    }

    public func setTranscribing() {
        NSLog("[DIAG] VoiceSearchSession state → transcribing")
        state = .transcribing
    }

    public func setDone(_ result: SearchResult) {
        NSLog("[DIAG] VoiceSearchSession state → done (transcript.len=\(result.transcript.count) matches=\(result.matches.count) topScore=\(result.matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a") confidence=\(result.topConfidence.rawValue))")
        state = .done(result)
    }

    public func setError(_ msg: String) {
        NSLog("[DIAG] VoiceSearchSession state → error msg=\"\(msg)\"")
        state = .error(msg)
    }

    public func reset() {
        if state != .idle {
            NSLog("[DIAG] VoiceSearchSession state → idle (reset)")
        }
        state = .idle
    }

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
    /// `asr`, then run the matcher off the @MainActor so a long query
    /// (hallucinated garbage with thousands of chars) can't freeze the UI.
    /// Every code path ends in a terminal state (`done` or `error`) — the
    /// previous version could leave the session stuck in `transcribing` if
    /// `matcher.match` blocked the @MainActor for minutes.
    public func runSearch(
        samples: [Float],
        asr: Asr,
        matcher: Matcher,
        config: AsrConfig = .default
    ) async throws -> SearchResult {
        setTranscribing()
        let transcribeStart = Date()
        let transcript: AsrTranscript
        do {
            transcript = try await asr.transcribe(samples, config: config)
        } catch {
            // Bubble up so the caller (AppContainer) can choose error vs
            // friendly empty-result handling. We don't setError here so the
            // caller can decide the user-facing wording.
            NSLog("[DIAG] VoiceSearchSession.runSearch ASR threw \(error.localizedDescription) afterMs=\(Int(Date().timeIntervalSince(transcribeStart) * 1000))")
            throw error
        }

        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[DIAG] VoiceSearchSession.runSearch ASR done transcribeMs=\(transcript.durationMs) raw.len=\(raw.count) raw.head120=\"\(String(raw.prefix(120)))\"")

        let matches: [Match]
        if raw.isEmpty {
            // Whisper said nothing (or hallucination guard suppressed it).
            // Skip the matcher entirely — empty query yields no matches and
            // would only waste cycles.
            matches = []
            NSLog("[DIAG] VoiceSearchSession.runSearch raw empty — skipping matcher")
        } else {
            // Move matcher.match off @MainActor. partial_ratio is O(n·m) over
            // 60K corpus lines — on a long query it can freeze the UI for
            // seconds (the original 2 min hang on the Telugu hallucination).
            // Task.detached at userInitiated priority keeps UI responsive.
            let matcherRef = matcher
            let query = raw
            let matchStart = Date()
            matches = await Task.detached(priority: .userInitiated) {
                matcherRef.match(query, topN: 5)
            }.value
            let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)
            NSLog("[DIAG] VoiceSearchSession.runSearch matcher done matchMs=\(matchMs) matches=\(matches.count) topScore=\(matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a")")
        }

        let result = SearchResult.from(transcript: raw, matches: matches)
        setDone(result)
        return result
    }
}
