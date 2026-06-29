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
///   matches accumulate as *challengers* in a multi-slot dict (Brief
///   #9.6) — up to ``maxChallengerSlots`` distinct shabads tracked
///   simultaneously, LRU-evicted at capacity. The engine swaps ONLY
///   when a challenger clears the evidence-and-margin gates (2
///   matches in 8-s window, latest ≥ 75, latest ≥ current peak − 15)
///   OR scores ≥ ``lockedSwapBypassScore`` (92) on a single match.
///   Tier-3 cross-shabad matches are filtered out entirely — they're
///   full-SGGS noise and never become challengers. Same-shabad
///   matches do NOT clear challengers (Brief #9.6 design change from
///   #9.4) so legitimate cross-shabad evidence can persist through
///   simran returns to the current shabad.
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

    /// Sliding-window evidence for a single candidate shabad. Used
    /// ONLY by DISCOVERING (single-slot lock-candidate accumulation).
    /// LOCKED-state cross-shabad challengers live in
    /// ``challengers`` — see Brief #9.6.
    private struct PendingCandidate {
        let shabadId: String
        var matches: [(time: Date, score: Double)]
    }
    private var pendingCandidate: PendingCandidate?

    /// **Multi-slot challenger evidence** for LOCKED-state shabad-
    /// swap consideration (Brief #9.6). Replaces the single
    /// `pendingCandidate` slot that #9.4 used in LOCKED — a single
    /// slot got demolished by every tier-3 noise hit, so legitimate
    /// evidence couldn't accumulate to 2 in the 5-s window. Now up
    /// to ``maxChallengerSlots`` (3) different shabads can be in
    /// flight simultaneously; tier-3 matches are filtered out
    /// entirely so they can't churn the dict.
    private struct ChallengerEvidence {
        let shabadId: String
        var matchCount: Int
        var latestScore: Double
        /// Line.id of the challenger's most recent match. Used as
        /// the highlight target when this challenger wins a swap —
        /// the user is presumed to be on whatever line they were
        /// last observed singing.
        var latestLineId: String
        var peakScore: Double
        let firstSeenAt: Date
        var latestSeenAt: Date
    }
    private var challengers: [String: ChallengerEvidence] = [:]

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
    /// Distinct from `lockedSwapBypassScore` (92, lower) since
    /// DISCOVERING has nothing to compare against — a single high-
    /// score commit there should be the strongest signal we accept.
    private static let discoveryFastLockScore: Double = 95.0
    /// Floor for accumulating evidence in DISCOVERING. Matches below
    /// this aren't tracked — too noisy to count toward a lock.
    private static let discoveryEvidenceFloor: Double = 80.0
    /// Number of in-window matches needed for an evidence-based lock
    /// in DISCOVERING. (Also reused as the threshold for evidence-
    /// based swaps in LOCKED.)
    private static let discoveryEvidenceCount: Int = 2

    /// Single-match swap from LOCKED when the candidate is very
    /// confident. Brief #9.6 tune: 95 → 92. Tier-3 matches are
    /// filtered out before reaching the bypass walk, so the
    /// bypass-by-single-match is effectively only firing for
    /// tier 0/1/2 hits at 92+ — a tighter threshold makes sense
    /// when the candidate is already a high-precision result.
    private static let lockedSwapBypassScore: Double = 92.0
    /// Floor for tracking a challenger in LOCKED. Matches below this
    /// are ignored entirely — not counted, no challenger created.
    private static let lockedChallengerScoreFloor: Double = 70.0
    /// The challenger's LATEST match must clear this score for the
    /// evidence path to qualify as a transition. Brief #9.6 tune:
    /// 80 → 75. Matches the loosening that helps the engine swap
    /// faster on sustained but moderate-confidence evidence.
    private static let lockedChallengerStrongScore: Double = 75.0
    /// The challenger's latest score must also be within this many
    /// points of the current shabad's recent peak — protects against
    /// swapping to a moderately-scoring shabad when the current one
    /// is dominating at 95+.
    private static let lockedSwapMarginBelow: Double = 15.0
    /// Maximum number of distinct cross-shabad challengers tracked
    /// simultaneously in LOCKED. When a 4th distinct shabadId arrives
    /// the LRU slot (oldest `latestSeenAt`) is evicted. Brief #9.6.
    /// Cap of 3 covers the typical kirtan case (current shabad +
    /// brief reference shabad + maybe one transitional shabad).
    private static let maxChallengerSlots: Int = 3

    /// Sliding window for evidence accumulation, in seconds. Used by
    /// BOTH the DISCOVERING single-slot logic AND the LOCKED multi-
    /// slot `challengers` dict (stale slots whose `latestSeenAt` is
    /// older than this are auto-evicted on the next match). Brief
    /// #9.6 tune: 5 → 8 to give legitimate excursions enough time
    /// to accumulate 2 matches even when interleaved with same-
    /// shabad simran or transient noise.
    private static let evidenceWindowSeconds: TimeInterval = 8.0

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
        challengers.removeAll(keepingCapacity: true)
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
        challengers.removeAll(keepingCapacity: true)
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

        // Brief #9.6 lazy cleanup — drop any stale challenger slots
        // before processing this match. Only matters in LOCKED but
        // costs nothing in DISCOVERING (challengers stays empty).
        pruneStaleChallengers()

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

        // Brief #9.6: do NOT clear `challengers` here. The previous
        // single-slot model wiped pendingCandidate on every same-
        // shabad match, but that pattern killed legitimate cross-
        // shabad evidence whenever the raagi briefly returned to
        // the current shabad mid-transition. Letting challengers
        // persist (subject to the 8-s stale window) gives a real
        // transition enough room to clear the 2-match threshold
        // even when interleaved with same-shabad simran.

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
        // Brief #9.6 REQ 2 — tier filter. Tier-3 matches are
        // full-SGGS noise during LOCKED; they never become or update
        // a challenger. Tier-3 matches for the CURRENT shabad still
        // go through `handleSameShabadMatchInLock` (different code
        // path); only cross-shabad tier-3 is filtered here.
        if tier > 2 {
            NSLog("[DIAG] StreamingRaagiModeEngine challenger ignored shabadId=\(shabadId) tier=\(tier) score=\(String(format: "%.1f", score)) (tier-3 noise)")
            return
        }

        // Drop weak challengers entirely — they're noise too.
        if score < Self.lockedChallengerScoreFloor {
            return
        }

        // Update existing slot or add a new one (with LRU eviction
        // when at capacity).
        let now = Date()
        if var existing = challengers[shabadId] {
            existing.matchCount += 1
            existing.latestScore = score
            existing.latestLineId = lineId
            if score > existing.peakScore {
                existing.peakScore = score
            }
            existing.latestSeenAt = now
            challengers[shabadId] = existing
        } else {
            evictLRUChallengerIfNeeded()
            challengers[shabadId] = ChallengerEvidence(
                shabadId: shabadId,
                matchCount: 1,
                latestScore: score,
                latestLineId: lineId,
                peakScore: score,
                firstSeenAt: now,
                latestSeenAt: now
            )
        }

        logChallengerSnapshot(updatedShabad: shabadId, tier: tier)

        // Walk all challengers and pick the best swap candidate
        // (highest latestScore that passes either gate).
        guard let winner = findBestSwapCandidate() else { return }
        await performSwap(
            shabadId: winner.entry.shabadId,
            lineId: winner.entry.latestLineId,
            score: winner.entry.latestScore,
            via: winner.via,
            seq: seq,
            tier: tier,
            challengerMatchCount: winner.entry.matchCount
        )
    }

    // MARK: - Challenger helpers (Brief #9.6)

    /// Drop any challenger whose `latestSeenAt` is older than
    /// `evidenceWindowSeconds`. Called at the top of every match so
    /// stale slots don't accumulate.
    private func pruneStaleChallengers() {
        if challengers.isEmpty { return }
        let now = Date()
        let staleKeys: [String] = challengers.compactMap { (k, v) in
            now.timeIntervalSince(v.latestSeenAt) > Self.evidenceWindowSeconds ? k : nil
        }
        for k in staleKeys {
            let staleSec = now.timeIntervalSince(challengers[k]!.latestSeenAt)
            NSLog("[DIAG] StreamingRaagiModeEngine challenger evicted shabadId=\(k) reason=stale staleSec=\(String(format: "%.1f", staleSec))")
            challengers.removeValue(forKey: k)
        }
    }

    /// Make room for a new challenger by evicting the LRU slot (the
    /// one with the oldest `latestSeenAt`). No-op if we're below
    /// capacity.
    private func evictLRUChallengerIfNeeded() {
        if challengers.count < Self.maxChallengerSlots { return }
        guard let lru = challengers.min(by: { $0.value.latestSeenAt < $1.value.latestSeenAt }) else { return }
        NSLog("[DIAG] StreamingRaagiModeEngine challenger evicted shabadId=\(lru.key) reason=lru")
        challengers.removeValue(forKey: lru.key)
    }

    /// Walk all challengers and return the one most worthy of a swap,
    /// or nil if none qualify. Brief #9.6 REQ 4 trigger logic:
    ///   - Evidence: matchCount ≥ 2 AND latestScore ≥ 75 AND
    ///     latestScore ≥ currentPeak − 15
    ///   - Bypass: latestScore ≥ 92 (single match)
    /// Ties broken by highest `latestScore`.
    private func findBestSwapCandidate() -> (entry: ChallengerEvidence, via: String)? {
        var best: (ChallengerEvidence, String)?
        for (_, c) in challengers {
            let qualifiesEvidence = c.matchCount >= 2
                && c.latestScore >= Self.lockedChallengerStrongScore
                && c.latestScore >= currentShabadRecentPeakScore - Self.lockedSwapMarginBelow
            let qualifiesBypass = c.latestScore >= Self.lockedSwapBypassScore
            if qualifiesEvidence || qualifiesBypass {
                if best == nil || c.latestScore > best!.0.latestScore {
                    // Prefer "bypass" label when the candidate alone
                    // would have qualified for it — informative for
                    // the trace.
                    best = (c, qualifiesBypass ? "bypass" : "evidence")
                }
            }
        }
        return best
    }

    private func logChallengerSnapshot(updatedShabad: String, tier: Int) {
        let entry = challengers[updatedShabad]!
        let slotsStr = challengers
            .sorted(by: { $0.value.matchCount > $1.value.matchCount })
            .map { "\($0.key):\($0.value.matchCount)" }
            .joined(separator: ",")
        let currentId = currentShabad?.id ?? "nil"
        NSLog("[DIAG] StreamingRaagiModeEngine challenger shabadId=\(updatedShabad) matches=\(entry.matchCount) latestScore=\(String(format: "%.1f", entry.latestScore)) peakScore=\(String(format: "%.1f", entry.peakScore)) tier=\(tier) slots=[\(slotsStr)] currentShabad=\(currentId) currentPeak=\(String(format: "%.1f", currentShabadRecentPeakScore))")
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
        // Brief #9.6: defensive — challengers should already be
        // empty in DISCOVERING (we don't touch the dict there) but
        // make sure the fresh lock starts with a clean slate.
        challengers.removeAll(keepingCapacity: true)
        lockState = .locked

        NSLog("[DIAG] StreamingRaagiModeEngine LOCK shabadId=\(shabadId) via=\(via) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine display update: first shabad shabadId=\(shabadId) lineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(lineId) currentDisplaySeq=\(seq)")
    }

    /// LOCKED → LOCKED transition with a new shabadId. Used by both
    /// the bypass (score ≥ 92, Brief #9.6) and evidence (challenger
    /// passes the gate) paths.
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
        // Brief #9.6: drop ALL challengers on swap. The winner has
        // just become the new currentShabad; any remaining
        // challenger slots are evidence accrued under the OLD
        // currentShabad context and shouldn't carry over.
        challengers.removeAll(keepingCapacity: true)
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
