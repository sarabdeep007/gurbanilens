import Foundation
import SwiftUI
import GurbaniLensCore  // Gurmukhi.fromDevanagari + Matcher

/// Cross-screen state for one voice-search round-trip. Held by ``AppContainer``
/// (app-scoped) and observed by the nav graph.
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
///                        liveMatches updating after each 300 ms debounce.
///                        **Phase A.3 reset (2026-06-21): payload is a
///                        SINGLE `text` field** (the latest WhisperKit
///                        `currentText` snapshot). The earlier
///                        confirmed/unconfirmed pair produced concatenated
///                        garbage when joined.
///   - ``committing``   — full ``Matcher.match`` running on the final
///                        accumulated transcript
///   - ``done``         — final ``SearchResult`` ready (shared with v1)
///
/// Every setter logs `[DIAG]`.
@MainActor
public final class VoiceSearchSession: ObservableObject {

    public enum State: Equatable {
        case idle
        // v1 cases
        case recording(peak: Float)
        case transcribing
        case matching
        // v2 cases — Phase A.3 reset: single `text` field
        case listening(
            text: String,
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
            case (.listening(let at, let am, let ae),
                  .listening(let bt, let bm, let be_)):
                return at == bt
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

    // MARK: - v1 setters

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
        text: String,
        liveMatches: [Match],
        bufferEnergy: Float
    ) {
        if case .listening = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → listening")
        }
        state = .listening(text: text, liveMatches: liveMatches, bufferEnergy: bufferEnergy)
    }

    public func setCommitting(query: String) {
        NSLog("[DIAG] VoiceSearchSession state → committing (query.len=\(query.count))")
        state = .committing(query: query)
    }

    // MARK: - Terminal setters

    public func setDone(_ result: SearchResult) {
        NSLog("[DIAG] VoiceSearchSession state → done (transcript.len=\(result.transcript.count) matches=\(result.matches.count) topScore=\(result.matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a") confidence=\(result.topConfidence.rawValue))")
        state = .done(result)
    }

    public func setError(_ msg: String) {
        NSLog("[DIAG] VoiceSearchSession state → error msg=\"\(msg)\"")
        state = .error(msg)
    }

    public func reset(reason: String = "unspecified") {
        if state != .idle {
            NSLog("[DIAG] VoiceSearchSession state → idle (reason=\(reason) previousState=\(String(describing: state)))")
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
    /// Phase A.3 reset: single `text` field replaces the previous
    /// confirmed / unconfirmed pair.
    public var listeningSnapshot: (text: String, matches: [Match], energy: Float)? {
        if case .listening(let t, let m, let e) = state {
            return (text: t, matches: m, energy: e)
        }
        return nil
    }

    // MARK: - v1 one-shot end-to-end

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
        let displayText = transcript.gurmukhi.isEmpty
            ? raw
            : transcript.gurmukhi.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[DIAG] VoiceSearchSession.runSearch ASR done transcribeMs=\(transcript.durationMs) raw.len=\(raw.count) raw.head120=\"\(String(raw.prefix(120)))\" gurmukhi.len=\(transcript.gurmukhi.count)")

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

        let result = SearchResult.from(transcript: displayText, matches: matches)
        setDone(result)
        return result
    }

    // MARK: - v2 streaming end-to-end

    /// **v2 mode entry.** Subscribes to the `StreamingASR` partials stream,
    /// updates `.listening(…)` on every partial with the SINGLE text
    /// snapshot (no segment concatenation), and runs
    /// ``Matcher.matchByFirstLetters`` with a 300 ms debounce so the
    /// live result list refreshes once per natural pause.
    ///
    /// Returns when the stream finishes — either because WhisperKit's
    /// silence-VAD tripped or the caller invoked ``commit(asr:matcher:)``.
    public func startStreaming(
        asr: StreamingASR,
        matcher: Matcher
    ) async throws {
        // AppContainer.startLiveStreamAndAwait already established
        // .listening on @MainActor before this await — see Bug A.
        let stream = try await asr.partials()

        var pendingMatchTask: Task<Void, Never>? = nil
        var lastMatchedQuery = ""

        for await partial in stream {
            // Bug B freeze-last-good guard. If the new partial drops total
            // content drastically vs the previous AND the previous was
            // substantive, suppress the new partial — keep the prior text
            // + matches in state, only update bufferEnergy.
            //
            // Dual-provider exception: when a Sarvam-tagged partial
            // arrives, it's the canonical Punjabi transcript and must
            // displace the previous (likely Whisper-live) text even if
            // shorter. Otherwise commit-time reads the rolling Whisper
            // transcript and the matcher loses Sarvam's quality.
            let prev = listeningSnapshot
            let prevLen = prev?.text.count ?? 0
            let newLen = partial.gurmukhi.count
            let dramaticShrink = prevLen > 12 && newLen < (prevLen / 2)
            let sarvamCanonical = partial.source == .sarvam && !partial.gurmukhi.isEmpty
            if dramaticShrink && !sarvamCanonical {
                NSLog("[DIAG] VoiceSearchSession.startStreaming Bug-B freeze-last-good (prev=\(prevLen) new=\(newLen) source=\(String(describing: partial.source))) — preserving previous transcript")
                setListening(
                    text: prev?.text ?? "",
                    liveMatches: prev?.matches ?? [],
                    bufferEnergy: partial.bufferEnergy
                )
                continue
            }
            if dramaticShrink && sarvamCanonical {
                NSLog("[DIAG] VoiceSearchSession.startStreaming Bug-B BYPASSED for Sarvam-canonical partial (prev=\(prevLen) new=\(newLen))")
            }

            // Snappy text + energy update. Preserve whatever liveMatches
            // are currently in state — the debounce task refreshes them.
            let currentLiveMatches = prev?.matches ?? []
            setListening(
                text: partial.gurmukhi,
                liveMatches: currentLiveMatches,
                bufferEnergy: partial.bufferEnergy
            )

            // Debounced matchByFirstLetters on the Latin form.
            pendingMatchTask?.cancel()

            let query = partial.latin.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty || query == lastMatchedQuery { continue }

            let matcherRef = matcher
            let scheduledQuery = query
            pendingMatchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms
                if Task.isCancelled { return }

                NSLog("[DIAG] VoiceSearchSession.startStreaming running live matcher query.len=\(scheduledQuery.count) query.head60=\"\(String(scheduledQuery.prefix(60)))\"")

                let matchStart = Date()
                let liveMatches = await Task.detached(priority: .userInitiated) {
                    matcherRef.matchByFirstLetters(scheduledQuery, topN: 5)
                }.value
                let matchMs = Int(Date().timeIntervalSince(matchStart) * 1000)
                NSLog("[DIAG] VoiceSearchSession.startStreaming matchByFirstLetters done matchMs=\(matchMs) matches=\(liveMatches.count) topScore=\(liveMatches.first.map { String(format: "%.1f", $0.score) } ?? "n/a")")

                if Task.isCancelled { return }
                // Bug R: the enclosing Task inherits this @MainActor
                // session's isolation under Swift 5.10+, so we're already
                // on MainActor here — direct property access is safe.
                // The previous explicit `await MainActor.run { … }` hop
                // is what tripped the unsafeForcedSync runtime check
                // (sync MainActor.run from a context already on MainActor).
                guard let self = self else { return }
                if case .listening(let t, _, let e) = self.state {
                    self.setListening(text: t, liveMatches: liveMatches, bufferEnergy: e)
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
    @discardableResult
    public func commit(
        asr: StreamingASR,
        matcher: Matcher
    ) async -> SearchResult {
        // Snapshot BEFORE stopping the asr so a final VAD-stop
        // setListening from the for-await loop doesn't race.
        // Phase A.3: snapshot.text is already Gurmukhi (we stored it
        // straight from partial.gurmukhi). For the matcher we need
        // Latin — re-derive via Latin.from on the Gurmukhi.fromDevanagari
        // output. But that's lossy. Better: re-derive Latin from the
        // ORIGINAL Devanagari, which we no longer store. Workaround:
        // route the Gurmukhi snapshot back through Latin.from. For
        // honest Gurmukhi/Devanagari input the Latin.from script
        // detection will pick Gurmukhi and produce a clean Latin form.
        let snapshot = listeningSnapshot
        let gurmukhiSource = snapshot?.text ?? ""
        let queryLatin = Latin.from(gurmukhiSource)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        NSLog("[DIAG] VoiceSearchSession.commit source.len=\(gurmukhiSource.count) queryLatin.len=\(queryLatin.count) queryLatin.head60=\"\(String(queryLatin.prefix(60)))\"")

        await asr.stop()
        setCommitting(query: gurmukhiSource)

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

        // SearchResult.transcript is the display field — Gurmukhi.
        let result = SearchResult.from(transcript: gurmukhiSource, matches: matches)
        setDone(result)
        return result
    }
}
