import Foundation
import SwiftUI
import GurbaniLensCore

/// **Raagi Mode engine** — continuous-listening loop that drives the
/// Raagi-follow UI. Brief #8 (2026-06-27).
///
/// The engine spins a single Task that loops over individual
/// utterances. Each loop iteration:
///   1. Spins up a fresh `StreamingASR` instance — fresh SileroVAD
///      state, fresh CloudMicCapture session.
///   2. Subscribes to its partials AsyncStream.
///   3. Drives the public state through `.listening` →
///      `.recording` based on the partials' `isSpeaking` flag (which
///      itself is now Silero-driven, Brief #7.2).
///   4. When the stream finishes (auto-stop on silence trail or
///      `stop()` called), captures the final transcript Partial.
///   5. Runs the matcher on the transcript.
///   6. Decides: jaikara (Commit 3 — placeholder until then), update
///      current shabad's highlight (same shabadId), switch shabad
///      (different shabadId), or no-op (low score).
///   7. Loops back for the next utterance.
///
/// **`.displaying` is sticky** — when a new utterance is mid-pipeline
/// the engine does NOT drop back to `.listening`; the shabad stays on
/// screen behind the bottom-of-screen waveform / status indicators.
/// That avoids visual flicker between utterances and matches what a
/// human-following raagi-bhai would do (keep the page, listen for
/// the next pangti).
///
/// **Cancellation**: `stop()` cancels the loop Task, awaits any
/// in-flight ASR to stop, drops back to `.idle`. Cache is cleared.
///
/// **Brief #8 Commit 1 scope**: this is the foundation. Direct
/// `Corpus.shabadLines(...)` fetch per match — no caching yet. The
/// ShabadCache layer lands in Commit 2; JaikaraDetector in Commit 3.
@MainActor
public final class RaagiModeEngine: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var state: RaagiModeState = .idle
    /// Live RMS for the waveform — set from per-tap energy Partials
    /// the providers yield (Brief #7.1's per-tap empty-text Partials).
    @Published public private(set) var bufferEnergy: Float = 0
    /// Provider name for the bottom-of-screen caption — snapshotted at
    /// `start()` from the first `StreamingASR.activeProviderDisplayName`.
    @Published public private(set) var providerLabel: String = ""
    /// Jaikara banner text — non-nil while the 3-s fade is in flight.
    /// Wired by Commit 3 (JaikaraDetector); stays nil for Commit 1.
    @Published public private(set) var jaikaraBanner: String?

    // MARK: - Deps + private state

    private let matcher: Matcher
    private let corpus: Corpus
    private let cache: ShabadCache
    private static let matchConfidenceThreshold: Double = 70.0

    private var loopTask: Task<Void, Never>?
    private var currentAsr: StreamingASR?
    /// Tracks the most recently displayed shabadId so we can detect
    /// same-shabad (highlight move) vs cross-shabad (switch display)
    /// transitions without unwrapping the `.displaying` state every
    /// time.
    private var lastDisplayedShabadId: String?

    public init(matcher: Matcher, corpus: Corpus) {
        self.matcher = matcher
        self.corpus = corpus
        self.cache = ShabadCache(corpus: corpus)
        NSLog("[DIAG] RaagiModeEngine.init")
    }

    // MARK: - Public API

    /// Begin the continuous-listen loop. Idempotent — repeated calls
    /// while already running are no-ops.
    public func start() {
        if loopTask != nil {
            NSLog("[DIAG] RaagiModeEngine.start ignored — already running")
            return
        }
        NSLog("[DIAG] RaagiModeEngine.start")
        state = .listening
        bufferEnergy = 0
        jaikaraBanner = nil
        lastDisplayedShabadId = nil
        loopTask = Task { [weak self] in
            await self?.runContinuousLoop()
        }
    }

    /// Stop the loop, tear down the ASR, drop back to `.idle`, clear
    /// the shabad cache so the next session starts fresh.
    public func stop() {
        NSLog("[DIAG] RaagiModeEngine.stop")
        loopTask?.cancel()
        loopTask = nil
        let asrToStop = currentAsr
        currentAsr = nil
        let cacheRef = cache
        Task {
            await asrToStop?.stop()
            await cacheRef.clear()
        }
        state = .idle
        bufferEnergy = 0
        jaikaraBanner = nil
        lastDisplayedShabadId = nil
    }

    // MARK: - Loop

    private func runContinuousLoop() async {
        // The outer while-loop guards against unexpected single-
        // utterance termination — each iteration is self-contained.
        while !Task.isCancelled {
            await runOneUtterance()
            if Task.isCancelled { break }
            // Tiny inter-utterance pause so a runaway loop (e.g.
            // capture.start throws synchronously every time) can't
            // burn 100 % CPU. Real utterances are seconds long; 100
            // ms here is invisible.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[DIAG] RaagiModeEngine continuous loop exited")
    }

    private func runOneUtterance() async {
        let asr = StreamingASR()
        currentAsr = asr
        let label = asr.activeProviderDisplayName
        if providerLabel != label { providerLabel = label }

        // Drop back to .listening unless we have a displayed shabad
        // that should stay sticky on screen.
        if case .displaying = state {
            // sticky — keep the shabad visible while VAD waits for
            // the next pangti.
        } else {
            state = .listening
        }

        let stream: AsyncStream<Partial>
        do {
            stream = try await asr.partials()
        } catch {
            NSLog("[DIAG] RaagiModeEngine asr.partials() threw: \(error.localizedDescription)")
            currentAsr = nil
            state = .error(error.localizedDescription)
            try? await Task.sleep(nanoseconds: 800_000_000)
            return
        }

        var finalTranscript = ""
        for await partial in stream {
            if Task.isCancelled { break }
            // Energy + waveform.
            if partial.bufferEnergy != bufferEnergy {
                bufferEnergy = partial.bufferEnergy
            }
            // VAD transition. Only flip the state if we're not
            // already showing a shabad (sticky-display rule).
            if partial.isSpeaking {
                if case .listening = state {
                    state = .recording
                }
                // While .displaying stays sticky we don't move to
                // .recording — the UI still has its previous shabad
                // visible. Once we have a transcript and a new
                // match, the .displaying transition fires below.
            }
            // Keep the latest transcript-bearing partial. The
            // provider's final yielded Partial is what we want
            // (utterance-buffered Cloud provider yields ONE final
            // transcript Partial after stream close; live providers
            // yield the rolling text — last value wins).
            if !partial.gurmukhi.isEmpty {
                finalTranscript = partial.gurmukhi
            }
        }
        // Stream closed — VAD silence trail or stop() called.
        await asr.stop()
        currentAsr = nil

        if Task.isCancelled { return }
        if finalTranscript.isEmpty {
            // Silence / sub-threshold utterance / VAD blip. Don't
            // change displayed state — keep prior shabad (if any) on
            // screen. Just go back to .listening.
            if case .displaying = state {
                // sticky.
            } else {
                state = .listening
            }
            return
        }

        await processUtterance(finalTranscript)
    }

    private func processUtterance(_ transcript: String) async {
        NSLog("[DIAG] RaagiModeEngine processUtterance head60=\"\(String(transcript.prefix(60)))\" len=\(transcript.count)")
        state = .processing(text: transcript)

        // Commit 3 will plug JaikaraDetector in here, BEFORE the
        // matcher. Skip for Commit 1.

        let queryLatin = Latin.from(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if queryLatin.isEmpty {
            NSLog("[DIAG] RaagiModeEngine queryLatin empty — keeping prior display")
            restoreStickyOrListening()
            return
        }

        let matcherRef = matcher
        let q = queryLatin
        let matches = await Task.detached(priority: .userInitiated) {
            matcherRef.match(q, topN: 5)
        }.value

        guard let top = matches.first, top.score >= Self.matchConfidenceThreshold else {
            let topScore = matches.first.map { String(format: "%.1f", $0.score) } ?? "n/a"
            NSLog("[DIAG] RaagiModeEngine no confident match topScore=\(topScore) threshold=\(Self.matchConfidenceThreshold) — keeping prior display")
            restoreStickyOrListening()
            return
        }

        let matchedShabadId = top.line.shabadId
        let matchedLineId = top.line.id
        NSLog("[DIAG] RaagiModeEngine match topScore=\(String(format: "%.1f", top.score)) shabadId=\(matchedShabadId) lineId=\(matchedLineId) ang=\(top.line.ang)")

        let fetched: FullShabad
        do {
            fetched = try await loadShabad(id: matchedShabadId)
        } catch {
            NSLog("[DIAG] RaagiModeEngine shabad fetch failed: \(error.localizedDescription)")
            restoreStickyOrListening()
            return
        }

        // Same-shabad: highlight move. Cross-shabad: switch display.
        if lastDisplayedShabadId == matchedShabadId {
            NSLog("[DIAG] RaagiModeEngine highlight move within shabadId=\(matchedShabadId)")
        } else if lastDisplayedShabadId != nil {
            NSLog("[DIAG] RaagiModeEngine shabad switch from=\(lastDisplayedShabadId ?? "nil") to=\(matchedShabadId)")
        } else {
            NSLog("[DIAG] RaagiModeEngine first shabad shabadId=\(matchedShabadId)")
        }
        lastDisplayedShabadId = matchedShabadId
        state = .displaying(shabad: fetched, lineId: matchedLineId)
    }

    /// Brief #8 Commit 2: routes through ShabadCache. Same shabad
    /// requested twice in a row → instant cache hit (no DB query on
    /// the second).
    private func loadShabad(id: String) async throws -> FullShabad {
        return try await cache.shabad(forId: id)
    }

    /// Helper for the "no match / empty transcript / fetch failed"
    /// paths — keeps a previously-displayed shabad visible (sticky
    /// rule), otherwise drops back to .listening.
    private func restoreStickyOrListening() {
        if case .displaying = state {
            return
        }
        if let lastId = lastDisplayedShabadId {
            // We had a shabad earlier but state somehow drifted off
            // .displaying — re-fetch and restore.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let restored = try? await self.loadShabad(id: lastId),
                   let firstLine = restored.lines.first {
                    self.state = .displaying(shabad: restored, lineId: firstLine.id)
                } else {
                    self.state = .listening
                }
            }
            return
        }
        state = .listening
    }
}
