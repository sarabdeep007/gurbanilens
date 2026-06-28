import Foundation
import SwiftUI
import GurbaniLensCore

/// **Streaming Raagi Mode engine** — server-side matched, evidence-
/// driven lock model. Brief #9-iOS (2026-06-27), reshaped in Brief
/// #9.4-iOS (2026-06-28) into a DISCOVERING / LOCKED state machine.
///
/// Drives the same ``RaagiModeViewModel`` surface as the buffered
/// engine (`currentShabad` / `currentLineId` / `audioState` /
/// `bufferEnergy` / `activeJaikara`), so ``RaagiModeScreen`` renders
/// it unchanged. The user toggles between engines via
/// `settings.streamingModeEnabled`.
///
/// ## State machine (Brief #9.4)
///
/// ```
///   ┌──────────────┐    fast lock OR  ┌──────────┐
///   │ DISCOVERING  │ ───2-match evidence──▶ │  LOCKED  │ ──┐
///   └──────────────┘                  └──────────┘   │
///         ▲                                  │       │
///         │                                  │       │ swap via
///         │   (no auto-exit; LOCKED is       ▼       │ evidence /
///         │    sticky; stop() resets)        ┌──────────┐  bypass
///         └──────────────────────────────────│  LOCKED  │◀─┘
///                                            │  (new id)│
///                                            └──────────┘
/// ```
///
/// - **DISCOVERING** is the entry state. `currentShabad` is nil and
///   the screen shows its "begin reciting" hint. Server-side matches
///   accumulate as evidence for a single candidate at a time. The
///   engine locks when EITHER a single match scores ≥
///   ``discoveryFastLockScore`` (95) OR two same-shabad matches each
///   ≥ ``discoveryEvidenceFloor`` (80) land within
///   ``evidenceWindowSeconds`` (5 s).
///
/// - **LOCKED** holds the displayed shabad through brief excursions,
///   simran/jaikara interludes, and tier-3 noise. Different-shabad
///   matches accumulate as a *challenger* — the engine swaps ONLY
///   when the challenger clears the evidence-and-margin gates
///   (2 matches in window, latest ≥ 80, latest ≥ current peak − 15)
///   OR the candidate scores ≥ ``lockedSwapBypassScore`` (95) on its
///   own. A same-shabad match clears any in-flight challenger
///   immediately — it proves the raagi is still on the locked shabad.
///
/// ## Why evidence, not hysteresis alone
///
/// Brief #9.2/#9.3's peak-only hysteresis (still preserved here as a
/// secondary defense) gates each match independently against the
/// current peak. In kirtan, raagis frequently sing 1-2 lines from a
/// reference shabad before returning to the current one — those
/// stray matches could clear hysteresis on their own and flicker the
/// display. The lock model requires *sustained* evidence — two
/// matches in the same 5-s window — which a brief 1-2-line excursion
/// won't generate.
///
/// ## Architecture
///
/// ```
///   StreamingMicCapture  ── 100 ms PCM16 chunks ──▶ StreamingProvider
///                          AsyncStream<StreamingEvent> ◀┘
///                                   │
///                                   ▼
///                        StreamingRaagiModeEngine (this class)
///                                   │
///                                   ▼     state machine: discovery/locked
///                                   ▼     evidence: pendingCandidate
///                                   ▼     peak: currentShabadRecentPeakScore
///                                   ▼
///                          @Published surface
///                                   │
///                                   ▼
///                          RaagiModeScreen UI
/// ```
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

    // MARK: - Lock state machine (Brief #9.4)

    private enum LockState {
        /// No shabad locked. `currentShabad` is nil. Server matches
        /// build evidence for a single candidate at a time.
        case discovering
        /// A shabad is locked + displayed. Cross-shabad matches
        /// accumulate as a challenger; same-shabad matches clear it.
        case locked
    }
    private var lockState: LockState = .discovering

    /// Sliding-window evidence for a single candidate shabad. In
    /// DISCOVERING this is the candidate-to-lock; in LOCKED it's the
    /// cross-shabad challenger. Single-candidate by design — a new
    /// shabad replaces the old one.
    private struct PendingCandidate {
        let shabadId: String
        var matches: [(time: Date, score: Double)]
    }
    private var pendingCandidate: PendingCandidate?

    // MARK: - Sticky peak (Brief #9.2/#9.3, retained as secondary defense)

    /// High-water-mark for current-shabad confidence. Used by the
    /// LOCKED challenger threshold (`latest ≥ peak − 15`) to prevent
    /// swaps to substantially weaker shabads even when challenger
    /// evidence accumulates. Reset to 0 in DISCOVERING.
    private var currentShabadRecentPeakScore: Double = 0
    /// Wall-clock timestamp when `currentShabadRecentPeakScore` was
    /// last refreshed. Brief #9.3 fix: refreshed on EVERY same-shabad
    /// match so the anchor stays alive during continuous singing.
    private var currentShabadRecentPeakTime: Date? = nil

    // MARK: - Tunables (Brief #9.4)

    private static let jaikaraBannerSeconds: Double = 3.0

    /// Single-match lock in DISCOVERING when the matcher is very
    /// confident. ≥ 95 means the server has effectively no doubt.
    private static let discoveryFastLockScore: Double = 95.0
    /// Floor for accumulating evidence in DISCOVERING. Matches below
    /// this aren't tracked — too noisy to count toward a lock.
    private static let discoveryEvidenceFloor: Double = 80.0
    /// Number of in-window matches needed for an evidence-based lock
    /// in DISCOVERING. (Also reused as the threshold for evidence-
    /// based swaps in LOCKED.)
    private static let discoveryEvidenceCount: Int = 2

    /// Single-match swap from LOCKED when the candidate is very
    /// confident (matches the discovery fast-lock bar).
    private static let lockedSwapBypassScore: Double = 95.0
    /// Floor for tracking a challenger in LOCKED. Matches below this
    /// are ignored entirely — not counted, no challenger created.
    private static let lockedChallengerScoreFloor: Double = 70.0
    /// The challenger's LATEST match must clear this score for the
    /// evidence path to qualify as a transition.
    private static let lockedChallengerStrongScore: Double = 80.0
    /// The challenger's latest score must also be within this many
    /// points of the current shabad's recent peak — protects against
    /// swapping to a moderately-scoring shabad when the current one
    /// is dominating at 95+.
    private static let lockedSwapMarginBelow: Double = 15.0

    /// Sliding window for evidence accumulation, in seconds. Matches
    /// older than this are pruned from `pendingCandidate.matches`
    /// before any threshold check.
    private static let evidenceWindowSeconds: TimeInterval = 5.0

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
        NSLog("[DIAG] StreamingRaagiModeEngine.start (state=discovering)")
        setAudioState(.listening)
        bufferEnergy = 0
        activeJaikara = nil
        currentDisplaySeq = 0
        currentShabadRecentPeakScore = 0
        currentShabadRecentPeakTime = nil
        lockState = .discovering
        pendingCandidate = nil
        sessionId = UUID().uuidString

        mic.onActivity = { [weak self] _, rms, vadActive in
            Task { @MainActor in
                self?.handleActivity(rms: rms, vadActive: vadActive)
            }
        }
        mic.onChunk = { [weak self] data, _ in
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
        NSLog("[DIAG] StreamingRaagiModeEngine.stop currentDisplaySeq=\(currentDisplaySeq) state=\(lockState)")
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
        lockState = .discovering
        pendingCandidate = nil
    }

    // MARK: - Activity → audioState

    private func handleActivity(rms: Float, vadActive: Bool) {
        if abs(rms - bufferEnergy) > 0.0001 {
            bufferEnergy = rms
        }
        if case .error = audioState { return }
        if vadActive {
            setAudioState(.recording)
        } else {
            setAudioState(.listening)
        }
    }

    // MARK: - Event routing

    private func handleEvent(_ event: StreamingEvent) async {
        switch event {
        case .ready(let sid):
            NSLog("[DIAG] StreamingRaagiModeEngine ready session_id=\(sid)")
            if case .error = audioState {
                setAudioState(.listening)
            }

        case .partial:
            // v1: ignore partials. Match events drive the lock model.
            break

        case .match(let seq, let shabadId, let lineId, let score, let tier, _, _):
            await handleMatch(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier)

        case .jaikara(_, let phrase):
            // Jaikara is a banner overlay; doesn't disturb lock or
            // challenger. Pass through unchanged (Brief #9.4 constraint).
            showJaikara(phrase)

        case .noMatch(let seq, let reason, _):
            NSLog("[DIAG] StreamingRaagiModeEngine no_match seq=\(seq) reason=\(reason)")

        case .disconnected(let reason):
            NSLog("[DIAG] StreamingRaagiModeEngine disconnected reason=\(reason)")
            setAudioState(.error("disconnected — reconnecting…"))
        }
    }

    // MARK: - Match handling (state-machine dispatch)

    private func handleMatch(
        seq: Int,
        shabadId: String,
        lineId: String,
        score: Double,
        tier: Int
    ) async {
        // Stale check — newer match already won display.
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (pre-fetch)")
            return
        }

        switch lockState {
        case .discovering:
            await handleMatchInDiscovery(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier)
        case .locked:
            if let currentId = currentShabad?.id, currentId == shabadId {
                handleSameShabadMatchInLock(seq: seq, lineId: lineId, score: score, tier: tier)
            } else {
                await handleDifferentShabadMatchInLock(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier)
            }
        }
    }

    // ── DISCOVERING ───────────────────────────────────────────────

    private func handleMatchInDiscovery(
        seq: Int,
        shabadId: String,
        lineId: String,
        score: Double,
        tier: Int
    ) async {
        // Fast lock: single very-confident match commits immediately.
        if score >= Self.discoveryFastLockScore {
            await lockTo(shabadId: shabadId, lineId: lineId, peakScore: score, via: "fast", seq: seq, tier: tier)
            return
        }

        // Below the evidence floor → noise, don't even track. Stay
        // in DISCOVERING quietly.
        if score < Self.discoveryEvidenceFloor {
            return
        }

        // Accumulate evidence for this candidate (or replace if a
        // different shabad).
        accumulateEvidence(shabadId: shabadId, score: score)
        pruneEvidenceWindow()

        guard let p = pendingCandidate else { return }
        if p.matches.count >= Self.discoveryEvidenceCount {
            let peakOfEvidence = p.matches.map(\.score).max() ?? score
            await lockTo(shabadId: p.shabadId, lineId: lineId, peakScore: peakOfEvidence, via: "evidence", seq: seq, tier: tier)
        }
    }

    // ── LOCKED + same shabad ──────────────────────────────────────

    private func handleSameShabadMatchInLock(
        seq: Int,
        lineId: String,
        score: Double,
        tier: Int
    ) {
        // #9.3 logic: refresh time unconditionally, raise peak score
        // only when stronger. Anchor stays alive during continuous
        // singing across oscillating scores.
        currentShabadRecentPeakTime = Date()
        if score > currentShabadRecentPeakScore {
            currentShabadRecentPeakScore = score
        }

        // A same-shabad match is the strongest possible signal that
        // the raagi is still on the locked shabad — clear any in-
        // flight challenger immediately so a brief excursion that
        // had started accumulating evidence loses its slot.
        if let oldP = pendingCandidate {
            NSLog("[DIAG] StreamingRaagiModeEngine challenger cleared reason=same_shabad_match previousChallenger=\(oldP.shabadId) matches=\(oldP.matches.count)")
            pendingCandidate = nil
        }

        let oldLine = currentLineId ?? "nil"
        currentLineId = lineId
        currentDisplaySeq = seq
        let currentId = currentShabad?.id ?? "nil"
        NSLog("[DIAG] StreamingRaagiModeEngine display update: same-shabad highlight from=\(oldLine) to=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(currentId) lineId=\(lineId) currentDisplaySeq=\(seq)")
    }

    // ── LOCKED + different shabad ─────────────────────────────────

    private func handleDifferentShabadMatchInLock(
        seq: Int,
        shabadId: String,
        lineId: String,
        score: Double,
        tier: Int
    ) async {
        // Drop weak challengers entirely — they're noise.
        if score < Self.lockedChallengerScoreFloor {
            return
        }

        // Bypass: very confident candidate swaps immediately.
        if score >= Self.lockedSwapBypassScore {
            await performSwap(shabadId: shabadId, lineId: lineId, score: score, via: "bypass", seq: seq, tier: tier, challengerMatchCount: 0)
            return
        }

        // Evidence path: accumulate + check thresholds.
        accumulateEvidence(shabadId: shabadId, score: score)
        pruneEvidenceWindow()

        guard let p = pendingCandidate else { return }
        let latest = p.matches.last?.score ?? score
        let matchCount = p.matches.count
        let currentId = currentShabad?.id ?? "nil"
        NSLog("[DIAG] StreamingRaagiModeEngine challenger shabadId=\(p.shabadId) matches=\(matchCount) latestScore=\(String(format: "%.1f", latest)) currentShabad=\(currentId) currentPeak=\(String(format: "%.1f", currentShabadRecentPeakScore))")

        let enoughMatches = matchCount >= Self.discoveryEvidenceCount
        let strongEnough = latest >= Self.lockedChallengerStrongScore
        let nearPeak = latest >= currentShabadRecentPeakScore - Self.lockedSwapMarginBelow
        if enoughMatches && strongEnough && nearPeak {
            await performSwap(shabadId: p.shabadId, lineId: lineId, score: latest, via: "evidence", seq: seq, tier: tier, challengerMatchCount: matchCount)
        }
    }

    // MARK: - Evidence helpers

    /// Append `(now, score)` to the existing candidate if it matches
    /// the same shabad, or start a fresh single-candidate slot
    /// (replacing any prior different-shabad candidate). Brief #9.4:
    /// single-candidate-at-a-time by design.
    private func accumulateEvidence(shabadId: String, score: Double) {
        if var existing = pendingCandidate, existing.shabadId == shabadId {
            existing.matches.append((Date(), score))
            pendingCandidate = existing
        } else {
            if let oldP = pendingCandidate {
                NSLog("[DIAG] StreamingRaagiModeEngine challenger cleared reason=new_candidate previousShabad=\(oldP.shabadId) matches=\(oldP.matches.count) newShabad=\(shabadId)")
            }
            pendingCandidate = PendingCandidate(shabadId: shabadId, matches: [(Date(), score)])
        }
    }

    /// Drop matches older than `evidenceWindowSeconds`. If the
    /// candidate ends up with no in-window matches, clear it
    /// entirely.
    private func pruneEvidenceWindow() {
        guard var existing = pendingCandidate else { return }
        let now = Date()
        let beforeCount = existing.matches.count
        existing.matches.removeAll { now.timeIntervalSince($0.time) > Self.evidenceWindowSeconds }
        if existing.matches.isEmpty {
            pendingCandidate = nil
            if beforeCount > 0 {
                NSLog("[DIAG] StreamingRaagiModeEngine challenger cleared reason=evidence_window_aged_out shabadId=\(existing.shabadId) prunedMatches=\(beforeCount)")
            }
        } else {
            pendingCandidate = existing
        }
    }

    // MARK: - Lock / swap transitions

    /// DISCOVERING → LOCKED transition. Fetches the shabad, sets
    /// display, primes peak tracking, transitions state.
    private func lockTo(
        shabadId: String,
        lineId: String,
        peakScore: Double,
        via: String,
        seq: Int,
        tier: Int
    ) async {
        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: shabadId)
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine lock fetch failed shabadId=\(shabadId): \(error.localizedDescription) — staying in DISCOVERING")
            return
        }
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch-lock)")
            return
        }

        currentShabad = fetched
        currentLineId = lineId
        currentShabadRecentPeakScore = peakScore
        currentShabadRecentPeakTime = Date()
        currentDisplaySeq = seq
        pendingCandidate = nil
        lockState = .locked

        NSLog("[DIAG] StreamingRaagiModeEngine LOCK shabadId=\(shabadId) via=\(via) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine display update: first shabad shabadId=\(shabadId) lineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(lineId) currentDisplaySeq=\(seq)")
    }

    /// LOCKED → LOCKED transition with a new shabadId. Used by both
    /// the bypass (score ≥ 95) and evidence (challenger passes the
    /// gate) paths.
    private func performSwap(
        shabadId: String,
        lineId: String,
        score: Double,
        via: String,
        seq: Int,
        tier: Int,
        challengerMatchCount: Int
    ) async {
        let fetched: FullShabad
        do {
            fetched = try await cache.shabad(forId: shabadId)
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine swap fetch failed shabadId=\(shabadId): \(error.localizedDescription) — keeping sticky display")
            return
        }
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch-swap)")
            return
        }

        let prevId = currentShabad?.id ?? "nil"
        currentShabad = fetched
        currentLineId = lineId
        currentShabadRecentPeakScore = score
        currentShabadRecentPeakTime = Date()
        currentDisplaySeq = seq
        pendingCandidate = nil
        // lockState stays .locked

        if via == "evidence" {
            NSLog("[DIAG] StreamingRaagiModeEngine SWAP from=\(prevId) to=\(shabadId) via=evidence challengerMatches=\(challengerMatchCount) latestScore=\(String(format: "%.1f", score))")
        } else {
            NSLog("[DIAG] StreamingRaagiModeEngine SWAP from=\(prevId) to=\(shabadId) via=\(via) score=\(String(format: "%.1f", score))")
        }
        NSLog("[DIAG] StreamingRaagiModeEngine display update: shabad swap from=\(prevId) to=\(shabadId) lineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(lineId) currentDisplaySeq=\(seq)")
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
