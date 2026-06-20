import Foundation
import SwiftUI
import GurbaniLensCore

/// Cross-screen state for one voice-search round-trip. Held by ``AppContainer``
/// (app-scoped) and observed by the nav graph. Mirrors
/// `android/.../domain/VoiceSearchSession.kt`.
///
/// ### v1 (one-shot) phases
///   - ``idle``         — Home screen, awaiting tap
///   - ``recording``    — mic capture in progress; live peak amplitude
///   - ``transcribing`` — Whisper running (one-shot)
///   - ``matching``     — matcher running (full Stage 0+1+2)
///   - ``done``         — ``SearchResult`` ready
///   - ``error``        — message surfaced to UI
///
/// ### v2 (live search-as-you-speak) phases
///   - ``listening``    — mic streaming; partial transcripts arriving;
///                        liveMatches updating after each 300 ms debounce
///   - ``committing``   — full ``Matcher.match`` running on the final
///                        accumulated transcript
///   - ``done``         — final ``SearchResult`` ready (shared with v1)
///
/// Every setter logs `[DIAG]` so we can correlate UI symptoms with the
/// actual state machine via the Xcode console.
@MainActor
public final class VoiceSearchSession: ObservableObject {

    public enum State: Equatable {
        case idle
        // v1 cases
        case recording(peak: Float)
        case transcribing
        case matching
        // v2 cases
        case listening(
            confirmedText: String,
            unconfirmedText: String,
            liveMatches: [Match],
            bufferEnergy: Float
        )
        case committing(query: String)
        // shared terminal cases
        case done(SearchResult)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.transcribing, .transcribing), (.matching, .matching):
                return true
            case (.recording(let a), .recording(let b)):
                return a == b
            case (.listening(let ac, let au, let am, let ae),
                  .listening(let bc, let bu, let bm, let be_)):
                return ac == bc && au == bu
                    && am.map(\.line.id) == bm.map(\.line.id)
                    && ae == be_
            case (.committing(let a), .committing(let b)):
                return a == b
            case (.done(let a), .done(let b)):
                return a.transcript == b.transcript
                    && a.matches.map(\.line.id) == b.matches.map(\.line.id)
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published public private(set) var state: State = .idle

    public init() {}

    // MARK: - v1 setters (untouched)

    public func setRecording(peak: Float = 0) {
        if case .recording = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → recording (initial peak=\(peak))")
        }
        state = .recording(peak: peak)
    }

    public func setTranscribing() {
        NSLog("[DIAG] VoiceSearchSession state → transcribing")
        state = .transcribing
    }

    public func setMatching() {
        NSLog("[DIAG] VoiceSearchSession state → matching")
        state = .matching
    }

    // MARK: - v2 setters

    /// Set/update the `.listening` state. Logs `[DIAG] state → listening`
    /// only on the initial transition to keep per-tick log volume down.
    public func setListening(
        confirmedText: String,
        unconfirmedText: String,
        liveMatches: [Match],
        bufferEnergy: Float
    ) {
        if case .listening = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → listening")
        }
        state = .listening(
            confirmedText: confirmedText,
            unconfirmedText: unconfirmedText,
            liveMatches: liveMatches,
            bufferEnergy: bufferEnergy
        )
    }

    public func setCommitting(query: String) {
        NSLog("[DIAG] VoiceSearchSession state → committing (query.len=\(query.count))")
        state = .committing(query: query)
    }

    // MARK: - Terminal setters (shared)

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

    // MARK: - Convenience accessors

    public var doneResult: SearchResult? {
        if case .done(let r) = state { return r } else { return nil }
    }

    public var errorMessage: String? {
        if case .error(let m) = state { return m } else { return nil }
    }

    public var recordingPeak: Float {
        if case .recording(let p) = state { return p } else { return 0 }
    }

    /// Snapshot of the current `.listening` payload (or nil otherwise).
    /// Phase B UI uses this from the View body to render sticky header +
    /// candidate list without pattern-matching the enum at the call site.
    public var listeningSnapshot: (confirmed: String, unconfirmed: String, matches: [Match], energy: Float)? {
        if case .listening(let c, let u, let m, let e) = state {
            return (confirmed: c, unconfirmed: u, matches: m, energy: e)
        }
        return nil
    }

    // MARK: - v1 one-shot end-to-end

    /// End-to-end one-shot search (v1 mode). Untouched in v2 — the
    /// streaming path goes through ``startStreaming(asr:matcher:)`` /
    /// ``commit(asr:matcher:)`` below instead.
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
            NSLog("[DIAG] VoiceSearchSession.runSearch ASR threw \(error.localizedDescription) afterMs=\(Int(Date().timeIntervalSince(transcribeStart) * 1000))")
            throw error
        }

        let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[DIAG] VoiceSearchSession.runSearch ASR done transcribeMs=\(transcript.durationMs) raw.len=\(raw.count) raw.head120=\"\(String(raw.prefix(120)))\"")

        let matches: [Match]
        if raw.isEmpty {
            matches = []
            NSLog("[DIAG] VoiceSearchSession.runSearch raw empty — skipping matcher + matching state")
        } else {
            setMatching()
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

    // MARK: - v2 streaming end-to-end

    /// **v2 mode entry.** Subscribes to the `StreamingASR` partials stream,
    /// updates `.listening(…)` on every partial, and runs
    /// ``Matcher.matchByFirstLetters`` with a 300 ms debounce so the
    /// live result list refreshes once per natural pause rather than per
    /// Whisper callback.
    ///
    /// Returns when the stream finishes — either because WhisperKit's
    /// silence-VAD tripped or the caller invoked ``commit(asr:matcher:)``
    /// / `asr.stop()`. The state at return time is `.listening(…)` with
    /// the final partial; the caller (typically `AppContainer`) then
    /// calls `commit()` to run the full fuzzy match and transition to
    /// `.done`.
    public func startStreaming(
        asr: StreamingASR,
        matcher: Matcher
    ) async throws {
        setListening(confirmedText: "", unconfirmedText: "", liveMatches: [], bufferEnergy: 0)
        let stream = try await asr.partials()

        var pendingMatchTask: Task<Void, Never>? = nil
        var lastMatchedQuery = ""

        for await partial in stream {
            // Step 1: snappy text + energy update. Preserve whatever
            // liveMatches are currently in state — the debounce task below
            // will refresh them when the debounce window elapses.
            let currentLiveMatches: [Match] = listeningSnapshot?.matches ?? []
            setListening(
                confirmedText: partial.confirmedText,
                unconfirmedText: partial.unconfirmedText,
                liveMatches: currentLiveMatches,
                bufferEnergy: partial.bufferEnergy
            )

            // Step 2: schedule a debounced matchByFirstLetters call.
            // Cancel the pending one (if any) so only the latest query
            // ever runs the matcher.
            pendingMatchTask?.cancel()

            let query = partial.latin.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty || query == lastMatchedQuery { continue }

            let matcherRef = matcher
            let scheduledQuery = query
            pendingMatchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
                if Task.isCancelled { return }

                let matchStart = Date()
                let liveMatches = await Task.detached(priority: .userInitiated) {
                    matcherRef.matchByFirstLetters(scheduledQuery, topN: 5)
                }.value
                let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)
                NSLog("[DIAG] VoiceSearchSession.startStreaming matchByFirstLetters done matchMs=\(matchMs) matches=\(liveMatches.count) topScore=\(liveMatches.first.map { String(format: "%.1f", $0.score) } ?? "n/a")")

                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self else { return }
                    // Update only the liveMatches slot — text + energy stay
                    // in sync with whatever the LATEST partial put there.
                    if case .listening(let c, let u, _, let e) = self.state {
                        self.setListening(
                            confirmedText: c,
                            unconfirmedText: u,
                            liveMatches: liveMatches,
                            bufferEnergy: e
                        )
                    }
                }
            }
            lastMatchedQuery = query
        }

        pendingMatchTask?.cancel()
        NSLog("[DIAG] VoiceSearchSession.startStreaming partials stream finished")
    }

    /// Stop the stream and run the full ``Matcher/match(_:topN:)`` on the
    /// accumulated transcript. Transitions through `.committing` →
    /// `.done(result)`.
    ///
    /// **Bug E fix (2026-06-20).** Phase A passed `confirmed + " " +
    /// unconfirmed` directly to the matcher — but those fields hold
    /// WhisperKit's raw Devanagari text and the matcher's index is Latin,
    /// so it would never produce useful matches. (The v1 MicSource path
    /// inadvertently took over via the Bug F audio-conflict and produced
    /// the only matches Deep saw.) We now route the Devanagari source
    /// through `Latin.from` at commit time before handing it to the full
    /// fuzzy matcher.
    ///
    /// Returns the final `SearchResult`.
    @discardableResult
    public func commit(
        asr: StreamingASR,
        matcher: Matcher
    ) async -> SearchResult {
        // Snapshot the listening payload BEFORE stopping the asr —
        // otherwise a final VAD-stop setListening from the for-await
        // loop could race.
        let devanagariSource: String = {
            if case .listening(let c, let u, _, _) = state {
                return (c + " " + u).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return ""
        }()
        let queryLatin = Latin.from(devanagariSource)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        NSLog("[DIAG] VoiceSearchSession.commit source.len=\(devanagariSource.count) queryLatin.len=\(queryLatin.count) queryLatin.head60=\"\(String(queryLatin.prefix(60)))\"")

        await asr.stop()
        setCommitting(query: devanagariSource)

        let matches: [Match]
        if queryLatin.isEmpty {
            matches = []
            NSLog("[DIAG] VoiceSearchSession.commit query empty — skipping full matcher")
        } else {
            let matcherRef = matcher
            let q = queryLatin
            let matchStart = Date()
            matches = await Task.detached(priority: .userInitiated) {
                matcherRef.match(q, topN: 5)
            }.value
            let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)
            NSLog("[DIAG] VoiceSearchSession.commit full matcher done matchMs=\(matchMs) matches=\(matches.count) topScore=\(matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a")")
        }

        // SearchResult.transcript is the display field — Phase B's Bug H
        // commit replaces this with Gurmukhi.fromDevanagari(devanagariSource)
        // so the user sees Gurmukhi script, not Devanagari. Until then we
        // ship the Devanagari source; better than showing the Latin form
        // which would surprise Sangat readers either way.
        let result = SearchResult.from(transcript: devanagariSource, matches: matches)
        setDone(result)
        return result
    }
}
