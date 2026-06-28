import Foundation
import SwiftUI
import GurbaniLensCore

/// **Streaming Raagi Mode engine** (Brief #9-iOS). Server-side
/// matching alternative to the local-cascade ``RaagiModeEngine``.
///
/// Drives the same ``RaagiModeViewModel`` surface that the buffered
/// engine does — `currentShabad` / `currentLineId` / `audioState` /
/// `bufferEnergy` / `activeJaikara` — so ``RaagiModeScreen`` renders
/// it unchanged. The user toggles between the two engines via the
/// `settings.streamingModeEnabled` AppStorage key.
///
/// **Architecture.**
/// ```
///   StreamingMicCapture  ── 100 ms PCM16 chunks ──▶ StreamingProvider
///                                                        │
///                          AsyncStream<StreamingEvent> ◀─┘
///                                   │
///                                   ▼
///                        StreamingRaagiModeEngine
///                          (this class)
///                                   │
///                                   ▼
///                          @Published surface
///                                   │
///                                   ▼
///                          RaagiModeScreen UI
/// ```
///
/// **No local matching.** All match decisions happen server-side;
/// this engine just fetches the matched shabad via ``ShabadCache``
/// (so the UI has the lines to render) and applies sticky-display
/// logic identical to the buffered engine's:
///   - Same shabad → update `currentLineId` only.
///   - Different shabad → swap.
///   - First match → set both.
///   - Out-of-order seqNum → drop as stale.
///
/// Jaikara is server-decided too — the server emits a `jaikara`
/// event with the matched phrase; the engine flashes the same 3-s
/// banner via ``activeJaikara``.
@MainActor
public final class StreamingRaagiModeEngine: ObservableObject {

    // MARK: - Published surface (RaagiModeViewModel conformance)

    @Published public private(set) var currentShabad: FullShabad?
    @Published public private(set) var currentLineId: String?
    @Published public private(set) var audioState: RaagiAudioState = .idle
    @Published public private(set) var bufferEnergy: Float = 0
    @Published public private(set) var providerLabel: String = "GurbaniLens Streaming"
    @Published public private(set) var activeJaikara: String?

    // MARK: - Deps

    private let corpus: Corpus
    private let cache: ShabadCache
    private let provider: StreamingProvider
    private let mic: StreamingMicCapture

    // MARK: - Session state

    private var sessionId: String = ""
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var jaikaraFadeTask: Task<Void, Never>?
    /// Sequence number of the most recent match that updated display.
    /// Match events with seq < `currentDisplaySeq` are dropped as
    /// stale. Server is the source of truth for monotonic ordering.
    private var currentDisplaySeq: Int = 0

    // MARK: - Sticky hysteresis (Brief #9.2-iOS)

    /// Highest recent match score for the currently-displayed shabad.
    /// Used together with ``currentShabadRecentPeakTime`` to gate
    /// different-shabad swaps: if the engine just saw the current
    /// shabad winning at 85+ within the last 2.5 s, a tier-3 swap to
    /// some unrelated shabad scoring 50-65 (a typical false-positive
    /// from full-SGGS noise) is rejected. Reset to 0 on session
    /// start/stop and when the display swaps to a new shabad.
    private var currentShabadRecentPeakScore: Double = 0
    /// Wall-clock timestamp when ``currentShabadRecentPeakScore``
    /// was last refreshed. nil when no recent peak. Real time (not
    /// seq-based) because peakAge in seconds is what gates the
    /// hysteresis window.
    private var currentShabadRecentPeakTime: Date? = nil

    private static let jaikaraBannerSeconds: Double = 3.0
    /// How long after a high-confidence current-shabad match the
    /// hysteresis still protects against swaps. 2.5 s = ~2 pangti
    /// durations at typical kirtan tempo — long enough to cover the
    /// gap between consecutive correct same-shabad matches, short
    /// enough that a true shabad change doesn't get stuck for long.
    private static let peakWindowSeconds: TimeInterval = 2.5
    /// A different-shabad candidate must score this many points
    /// below the recent peak to be rejected. With peak=95.5,
    /// requiredMin = 90.5 — a candidate at 57 is clearly noise,
    /// while one at 91 is plausibly a real swap (handled by the
    /// bypass below).
    private static let swapMarginBelow: Double = 5.0
    /// Hysteresis only engages when the recent peak is at least
    /// this high. Below 85 we trust the matcher: if the current
    /// shabad isn't winning strongly, any new same-or-better swap
    /// candidate should be accepted.
    private static let highConfidenceFloor: Double = 85.0
    /// Bypass the hysteresis when the candidate scores at or above
    /// this. A 90+ tier-3 match is the server expressing strong
    /// confidence in a new shabad; trust it and swap regardless of
    /// current-shabad peak.
    private static let alwaysAllowSwapAbove: Double = 90.0

    // MARK: - Init

    public init(corpus: Corpus, provider: StreamingProvider) {
        self.corpus = corpus
        self.cache = ShabadCache(corpus: corpus)
        self.provider = provider
        self.mic = StreamingMicCapture()
        NSLog("[DIAG] StreamingRaagiModeEngine.init")
    }

    // MARK: - Public lifecycle

    public func start() {
        if eventTask != nil {
            NSLog("[DIAG] StreamingRaagiModeEngine.start ignored — already running")
            return
        }
        NSLog("[DIAG] StreamingRaagiModeEngine.start")
        setAudioState(.listening)
        bufferEnergy = 0
        activeJaikara = nil
        currentDisplaySeq = 0
        currentShabadRecentPeakScore = 0
        currentShabadRecentPeakTime = nil
        sessionId = UUID().uuidString
        // Sticky display survives session re-entry if it wasn't
        // explicitly stop()'ed — defensive parity with the buffered
        // engine's flow.

        mic.onActivity = { [weak self] _, rms, vadActive in
            Task { @MainActor in
                self?.handleActivity(rms: rms, vadActive: vadActive)
            }
        }
        mic.onChunk = { [weak self] data, _ in
            // sendAudio is thread-safe; no hop required.
            self?.provider.sendAudio(data)
        }

        // Subscribe to events BEFORE connecting so a fast .ready
        // doesn't race the subscription.
        let events = provider.events()
        eventTask = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { return }
                await self?.handleEvent(event)
            }
        }

        // Connect + sendInit + start mic. Errors surface via
        // audioState; the user can recover by exiting and re-entering
        // Raagi Mode.
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.provider.connect()
                self.provider.sendInit(sessionId: self.sessionId)
                try self.mic.start()
            } catch {
                NSLog("[DIAG] StreamingRaagiModeEngine connect/mic start failed: \(error.localizedDescription)")
                self.setAudioState(.error(error.localizedDescription))
            }
        }
    }

    public func stop() {
        NSLog("[DIAG] StreamingRaagiModeEngine.stop currentDisplaySeq=\(currentDisplaySeq)")
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        jaikaraFadeTask?.cancel()
        jaikaraFadeTask = nil
        mic.stop()
        provider.disconnect()
        let cacheRef = cache
        Task { await cacheRef.clear() }
        setAudioState(.idle)
        bufferEnergy = 0
        activeJaikara = nil
        currentShabad = nil
        currentLineId = nil
        currentDisplaySeq = 0
        currentShabadRecentPeakScore = 0
        currentShabadRecentPeakTime = nil
    }

    // MARK: - Activity → audioState

    private func handleActivity(rms: Float, vadActive: Bool) {
        if abs(rms - bufferEnergy) > 0.0001 {
            bufferEnergy = rms
        }
        // Don't override a sticky error — the user can read the
        // status until they re-enter Raagi Mode.
        if case .error = audioState { return }
        if vadActive {
            setAudioState(.recording)
        } else {
            setAudioState(.listening)
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ event: StreamingEvent) async {
        switch event {
        case .ready(let sid):
            NSLog("[DIAG] StreamingRaagiModeEngine ready session_id=\(sid)")
            // Clear any disconnect error from a prior reconnect cycle.
            if case .error = audioState {
                setAudioState(.listening)
            }

        case .partial:
            // v1: ignore partials. Match events are what move the UI.
            // Future: a `.processing` audioState pulse on isFinal=true.
            break

        case .match(let seq, let shabadId, let lineId, let score, let tier, _, _):
            await handleMatch(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier)

        case .jaikara(_, let phrase):
            showJaikara(phrase)

        case .noMatch(let seq, let reason, _):
            NSLog("[DIAG] StreamingRaagiModeEngine no_match seq=\(seq) reason=\(reason)")
            // No display change. Sticky shabad stays.

        case .disconnected(let reason):
            NSLog("[DIAG] StreamingRaagiModeEngine disconnected reason=\(reason)")
            // Provider auto-reconnects (exponential backoff). Surface
            // a transient error label; next `.ready` clears it.
            setAudioState(.error("disconnected — reconnecting…"))
        }
    }

    private func handleMatch(
        seq: Int,
        shabadId: String,
        lineId: String,
        score: Double,
        tier: Int
    ) async {
        // Stale check #1: pre-anything.
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (pre-fetch)")
            return
        }

        // ── Same-shabad fast path ─────────────────────────────────
        // Brief #9.2-iOS: same-shabad match refreshes the recent-
        // peak score (used to gate cross-shabad swaps) and updates
        // the highlighted lineId. No cache fetch needed — the
        // shabad is already on screen.
        if let currentId = currentShabad?.id, currentId == shabadId {
            refreshCurrentShabadPeak(score: score)
            let oldLine = currentLineId ?? "nil"
            currentLineId = lineId
            currentDisplaySeq = seq
            NSLog("[DIAG] StreamingRaagiModeEngine display update: same-shabad highlight from=\(oldLine) to=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
            NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(lineId) currentDisplaySeq=\(seq)")
            return
        }

        // ── Different-shabad path: hysteresis check FIRST ─────────
        // Brief #9.2-iOS Bug 1 fix. If the current shabad just
        // scored 85+ within the peakWindow, reject low-score swaps
        // BEFORE paying the cache fetch.
        if shouldRejectSwap(candidateShabadId: shabadId, candidateScore: score, seq: seq) {
            return
        }

        // Hysteresis passed. Fetch + apply the swap.
        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: shabadId)
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine shabad fetch failed shabadId=\(shabadId): \(error.localizedDescription) — keeping sticky display")
            return
        }
        // Stale check #2: post-fetch (cache miss may have hit corpus
        // on a background queue, giving newer events a chance to win).
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch)")
            return
        }

        if let prev = currentShabad {
            currentShabad = fetched
            currentLineId = lineId
            NSLog("[DIAG] StreamingRaagiModeEngine display update: shabad swap from=\(prev.id) to=\(shabadId) lineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
        } else {
            currentShabad = fetched
            currentLineId = lineId
            NSLog("[DIAG] StreamingRaagiModeEngine display update: first shabad shabadId=\(shabadId) lineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
        }
        currentDisplaySeq = seq
        // Reset peak to the new shabad's score — start a fresh
        // hysteresis window protecting THIS shabad against the next
        // round of swaps.
        currentShabadRecentPeakScore = score
        currentShabadRecentPeakTime = Date()
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(lineId) currentDisplaySeq=\(seq)")
    }

    /// Refresh the sticky peak for the current shabad. Brief #9.2-iOS.
    /// Update if EITHER the incoming score is higher than the stored
    /// peak, OR the stored peak has aged out of the peakWindow. The
    /// second case lets the peak track downwards over time — if the
    /// user is now getting moderate scores instead of high ones, the
    /// peak shouldn't stay artificially elevated forever and keep
    /// blocking legitimate swaps.
    private func refreshCurrentShabadPeak(score: Double) {
        let peakAge = currentShabadRecentPeakTime.map { Date().timeIntervalSince($0) } ?? .infinity
        if score > currentShabadRecentPeakScore || peakAge > Self.peakWindowSeconds {
            currentShabadRecentPeakScore = score
            currentShabadRecentPeakTime = Date()
        }
    }

    /// Hysteresis gate for cross-shabad swaps. Returns `true` if the
    /// engine should reject this swap candidate (logs the DIAG line);
    /// `false` if the swap should proceed. Brief #9.2-iOS.
    ///
    /// Logic:
    ///   - If candidate score is at or above ``alwaysAllowSwapAbove``
    ///     (90), bypass — the server's very confident, trust it.
    ///   - Else if the current shabad has a recent (< peakWindow)
    ///     peak at or above ``highConfidenceFloor`` (85), require
    ///     the candidate to score at least `peak - swapMarginBelow`
    ///     (peak - 5). Below that, reject.
    ///   - Else allow (no recent high-confidence baseline to
    ///     protect; defer to the matcher).
    private func shouldRejectSwap(candidateShabadId: String, candidateScore: Double, seq: Int) -> Bool {
        let peakAge = currentShabadRecentPeakTime.map { Date().timeIntervalSince($0) } ?? .infinity
        let recentHighConfidence = (currentShabadRecentPeakScore >= Self.highConfidenceFloor)
            && (peakAge < Self.peakWindowSeconds)
        let bypassAllowed = candidateScore >= Self.alwaysAllowSwapAbove
        if recentHighConfidence && !bypassAllowed {
            let requiredMin = currentShabadRecentPeakScore - Self.swapMarginBelow
            if candidateScore < requiredMin {
                let currentId = currentShabad?.id ?? "nil"
                NSLog("[DIAG] StreamingRaagiModeEngine swap rejected seq=\(seq) candidateShabad=\(candidateShabadId) candidateScore=\(String(format: "%.1f", candidateScore)) currentShabad=\(currentId) peakScore=\(String(format: "%.1f", currentShabadRecentPeakScore)) peakAge=\(String(format: "%.2f", peakAge)) requiredMin=\(String(format: "%.1f", requiredMin))")
                return true
            }
        }
        return false
    }

    // MARK: - Jaikara

    private func showJaikara(_ text: String) {
        jaikaraFadeTask?.cancel()
        activeJaikara = text
        jaikaraFadeTask = Task { [weak self] in
            let nanos = UInt64(Self.jaikaraBannerSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            guard let self else { return }
            self.activeJaikara = nil
        }
    }

    // MARK: - Audio-state helper

    private func setAudioState(_ next: RaagiAudioState) {
        if audioState == next { return }
        NSLog("[DIAG] StreamingRaagiModeEngine.audioState: \(audioState) → \(next)")
        audioState = next
    }
}

extension StreamingRaagiModeEngine: RaagiModeViewModel {}
