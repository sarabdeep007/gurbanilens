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

    /// State machine reshape (Brief #7, 2026-06-25) — collapse the v1
    /// + v2 muddle into a coherent 6-state set. Old states
    /// (transcribing, matching, searching) collapse into `.processing`.
    /// Old `.recording(peak)` (v1 bulk-capture) collapses into the
    /// shared `.recording(text, matches, bufferEnergy)` with empty
    /// text/matches. New `.listening(bufferEnergy)` represents "mic
    /// on, VAD waiting for speech" (Silero VAD adds this distinction).
    public enum State: Equatable {
        case idle
        /// **VAD waiting.** Mic is on, Silero hasn't crossed the speech
        /// threshold yet. UI shows the waveform in idle (gray-blue)
        /// colour. The `bufferEnergy` drives waveform animation.
        case listening(bufferEnergy: Float)
        /// **Capturing.** VAD has detected speech (or v1 bulk capture
        /// is running). Live transcripts + match candidates accumulate
        /// in `text` / `liveMatches`. For v1 one-shot mode `text` +
        /// `liveMatches` stay empty — only `bufferEnergy` updates.
        case recording(
            text: String,
            liveMatches: [Match],
            bufferEnergy: Float
        )
        /// **ASR + matcher running.** Audio capture has stopped; the
        /// full ``Matcher.match`` is running on the accumulated
        /// transcript. `text` is the Gurmukhi snapshot the matcher is
        /// processing — displayed under the "ਖੋਜ ਰਹੇ ਹਾਂ…" spinner.
        case processing(text: String)
        // shared terminal cases
        case done(SearchResult)
        case error(String)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.listening(let a), .listening(let b)):
                return a == b
            case (.recording(let at, let am, let ae),
                  .recording(let bt, let bm, let be_)):
                return at == bt
                    && am.map(\.line.id) == bm.map(\.line.id)
                    && ae == be_
            case (.processing(let a), .processing(let b)):
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

    /// Human-readable name of the StreamingASR provider currently
    /// running this session. Set in `startStreaming` from the
    /// already-instantiated provider's `displayName` so the
    /// LiveResultsScreen caption reflects RUNTIME truth, not the
    /// possibly-stale @AppStorage picker value. Empty string when no
    /// session is active. (Deep's 2026-06-24 bug: caption flipped to
    /// "Sarvam" mid-session while Gemini was still the real backend,
    /// because the caption was computed straight from @AppStorage
    /// instead of the live provider.)
    @Published public private(set) var providerLabel: String = ""

    public init() {}

    // MARK: - v1 setters (compat — map onto new state shape)

    /// v1 bulk-capture entry point. Maps onto the shared `.recording`
    /// state with empty text + matches (v1 doesn't have live
    /// partials). Only the `bufferEnergy` field updates per tick to
    /// drive the VU meter.
    public func setRecording(peak: Float = 0) {
        if case .recording = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → recording (v1 bulk peak=\(peak))")
        }
        state = .recording(text: "", liveMatches: [], bufferEnergy: peak)
    }

    /// v1 ASR-running marker. Collapses into `.processing` per the
    /// Brief #7 state reshape — UI shows the same "Searching…" spinner
    /// either way.
    public func setTranscribing() {
        NSLog("[DIAG] VoiceSearchSession state → processing (v1 transcribing)")
        state = .processing(text: "")
    }

    /// v1 matcher-running marker. Same `.processing` collapse — the
    /// transcript is now known so we carry it as `text`.
    public func setMatching(text: String = "") {
        NSLog("[DIAG] VoiceSearchSession state → processing (v1 matching text.len=\(text.count))")
        state = .processing(text: text)
    }

    // MARK: - v2 setters

    /// **VAD waiting.** Mic is on; Silero hasn't crossed the speech
    /// threshold yet. `bufferEnergy` drives the waveform.
    public func setListening(bufferEnergy: Float = 0) {
        if case .listening = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → listening (VAD waiting)")
        }
        state = .listening(bufferEnergy: bufferEnergy)
    }

    /// **Capturing.** v2 streaming entered the recording phase; live
    /// transcripts + match candidates flow through. Logs only on
    /// initial transition to keep per-partial log volume down.
    public func setRecording(
        text: String,
        liveMatches: [Match],
        bufferEnergy: Float
    ) {
        if case .recording = state {} else {
            NSLog("[DIAG] VoiceSearchSession state → recording (v2 VAD active)")
        }
        state = .recording(text: text, liveMatches: liveMatches, bufferEnergy: bufferEnergy)
    }

    /// ASR + matcher running on the accumulated transcript. `reason`
    /// distinguishes silence_timeout / manual_stop / etc. in DIAG logs.
    public func setProcessing(text: String, reason: String = "manual") {
        NSLog("[DIAG] VoiceSearchSession state → processing (reason=\(reason) text.len=\(text.count) text.head40=\"\(String(text.prefix(40)))\")")
        state = .processing(text: text)
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
        providerLabel = ""
    }

    // MARK: - Convenience accessors

    public var doneResult: SearchResult? {
        if case .done(let r) = state { return r } else { return nil }
    }

    public var errorMessage: String? {
        if case .error(let m) = state { return m } else { return nil }
    }

    public var recordingPeak: Float {
        if case .recording(_, _, let e) = state { return e }
        if case .listening(let e) = state { return e }
        return 0
    }

    /// Snapshot of the current `.recording` payload (or nil otherwise).
    /// Renamed from `listeningSnapshot` 2026-06-25 alongside the state
    /// machine reshape — what was "listening with text/matches" is now
    /// `.recording`.
    public var recordingSnapshot: (text: String, matches: [Match], energy: Float)? {
        if case .recording(let t, let m, let e) = state {
            return (text: t, matches: m, energy: e)
        }
        return nil
    }

    /// Back-compat alias for the old name. Some external consumers may
    /// still reference `listeningSnapshot`; route through to the new
    /// name to avoid breaking them.
    public var listeningSnapshot: (text: String, matches: [Match], energy: Float)? {
        return recordingSnapshot
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
            setMatching(text: displayText)
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
        // Snapshot the provider label first so the LiveResultsScreen
        // caption reflects the actually-running backend (runtime
        // truth) the moment the stream opens — see Deep's 2026-06-24
        // bug where the caption read from @AppStorage drifted away
        // from the cached StreamingASR instance.
        let label = asr.activeProviderDisplayName
        providerLabel = label
        NSLog("[DIAG] VoiceSearchSession provider attached label='\(label)'")

        let stream = try await asr.partials()

        var pendingMatchTask: Task<Void, Never>? = nil
        var lastMatchedQuery = ""

        // Silence auto-stop (added 2026-06-23). Track time of last
        // above-threshold audio energy across partials; when 2.5 s of
        // continuous silence has passed since the last speech sample
        // AND the user actually spoke at some point, break the loop.
        // The caller (AppContainer.startLiveStreamAndAwait) sees a
        // natural return and runs commit → asr.stop() teardown.
        // Below-threshold partials before the first speech sample are
        // ignored so a quiet startup doesn't auto-stop the session.
        var lastSpeechTime = Date()
        var hasHeardSpeech = false
        let silenceTimeoutSec: TimeInterval = 2.5
        let speechEnergyThreshold: Float = 0.02

        // Self-correcting transcript (added 2026-06-23). When the live
        // matcher returns a high-confidence top match (score ≥ 90),
        // override the raw ASR text with the matched line's canonical
        // Gurmukhi. Reverts to raw text when the matcher's next pass
        // drops below threshold. Captured here so both the snappy
        // setListening path below AND the post-match Task can read /
        // write it without an actor hop.
        var lastConfidentDisplayText: String? = nil
        let selfCorrectScoreThreshold: Double = 90.0

        for await partial in stream {
            // Silence tracking — always run, regardless of partial
            // content. Energy is per-tap; even transcript-less partials
            // (Sarvam/dual energy-only Partials) carry it.
            let now = Date()
            if partial.bufferEnergy > speechEnergyThreshold {
                hasHeardSpeech = true
                lastSpeechTime = now
            } else if hasHeardSpeech {
                let silentFor = now.timeIntervalSince(lastSpeechTime)
                if silentFor > silenceTimeoutSec {
                    NSLog("[DIAG] VoiceSearchSession silence auto-stop fired after \(String(format: "%.2f", silentFor))s idle")
                    break
                }
            }

            // VAD-aware state transition (Brief #7, 2026-06-25): if the
            // partial reports speech (Silero-driven `isSpeaking` flag
            // from CloudMicCapture) OR it carries non-empty transcript
            // text, transition to `.recording`. Otherwise stay in
            // `.listening`. Once we've entered `.recording`, never go
            // back to `.listening` until the loop ends — energy-only
            // partials between words are normal, not "VAD waiting".
            let alreadyRecording: Bool = {
                if case .recording = state { return true } else { return false }
            }()
            let shouldTransitionToRecording = partial.isSpeaking || !partial.gurmukhi.isEmpty
            if !alreadyRecording && !shouldTransitionToRecording {
                // Still VAD-waiting; update energy for waveform only.
                setListening(bufferEnergy: partial.bufferEnergy)
                continue
            }

            // From here we're in (or transitioning to) `.recording`.
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
            let prev = recordingSnapshot
            let prevLen = prev?.text.count ?? 0
            let newLen = partial.gurmukhi.count
            let dramaticShrink = prevLen > 12 && newLen < (prevLen / 2)
            let sarvamCanonical = partial.source == .sarvam && !partial.gurmukhi.isEmpty
            if dramaticShrink && !sarvamCanonical {
                NSLog("[DIAG] VoiceSearchSession.startStreaming Bug-B freeze-last-good (prev=\(prevLen) new=\(newLen) source=\(String(describing: partial.source))) — preserving previous transcript")
                setRecording(
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
            //
            // Display-text priority:
            //   1. lastConfidentDisplayText if the matcher has locked
            //      a high-confidence top — that survives until matcher
            //      confidence drops in a later pass.
            //   2. partial.gurmukhi if the partial actually carries
            //      transcript text (Whisper-live partial, Sarvam
            //      segment).
            //   3. prev.text — energy-only partials (Sarvam's
            //      recordPeak yields empty text/gurmukhi at ~10/sec
            //      to drive the VU meter) MUST NOT wipe the
            //      accumulated transcript or the placeholder
            //      "ਸੁਣ ਰਿਹਾ ਹਾਂ…" flashes over every word the user
            //      speaks (Deep's 2026-06-24 bug report). The Bug-B
            //      freeze-last-good guard only fires for prevLen > 12,
            //      so short transcripts were also being wiped — this
            //      catches every length.
            let currentLiveMatches = prev?.matches ?? []
            let snappyText: String
            if let confident = lastConfidentDisplayText {
                snappyText = confident
            } else if !partial.gurmukhi.isEmpty {
                snappyText = partial.gurmukhi
            } else {
                snappyText = prev?.text ?? ""
            }
            setRecording(
                text: snappyText,
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
                guard let self = self else { return }

                // Self-correcting transcript: when the top match crosses
                // selfCorrectScoreThreshold, latch the canonical
                // Gurmukhi as the display text until the next pass
                // either re-confirms or drops below threshold.
                if let top = liveMatches.first, top.score >= selfCorrectScoreThreshold {
                    let matched = top.line.gurmukhiUnicode
                        ?? Gurmukhi.fromAnmolLipi(top.line.gurmukhi)
                    lastConfidentDisplayText = matched
                    NSLog("[DIAG] VoiceSearchSession transcript self-correct applied topScore=\(String(format: "%.1f", top.score)) matched.head40=\"\(String(matched.prefix(40)))\"")
                } else {
                    if lastConfidentDisplayText != nil {
                        NSLog("[DIAG] VoiceSearchSession transcript self-correct cleared (top dropped below threshold)")
                    }
                    lastConfidentDisplayText = nil
                }

                if case .recording(let t, _, let e) = self.state {
                    let displayText = lastConfidentDisplayText ?? t
                    self.setRecording(text: displayText, liveMatches: liveMatches, bufferEnergy: e)
                }
            }
            lastMatchedQuery = query
        }

        pendingMatchTask?.cancel()
        NSLog("[DIAG] VoiceSearchSession.startStreaming partials stream finished")
    }

    /// Stop the stream and run the full ``Matcher/match(_:topN:)`` on the
    /// accumulated transcript. Transitions through `.searching` →
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
        let snapshot = recordingSnapshot
        let gurmukhiSource = snapshot?.text ?? ""
        let queryLatin = Latin.from(gurmukhiSource)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        NSLog("[DIAG] VoiceSearchSession.commit source.len=\(gurmukhiSource.count) queryLatin.len=\(queryLatin.count) queryLatin.head60=\"\(String(queryLatin.prefix(60)))\"")

        await asr.stop()
        setProcessing(text: gurmukhiSource, reason: "commit")

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
