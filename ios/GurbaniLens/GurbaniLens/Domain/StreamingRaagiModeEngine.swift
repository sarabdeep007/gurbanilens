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

    // MARK: - First-letter local match (Brief #9.7)

    /// Precomputed FL signatures for every pangti in the currently-
    /// locked shabad. Snapshotted on lock/swap so partial-event FL
    /// matching avoids actor hops into ShabadCache on every
    /// transcript update. Empty in DISCOVERING; cleared on stop().
    private var currentShabadFLSigs: [String: [String]] = [:]
    /// Brief #9.16-iOS: safely-unique starter map for the currently-
    /// locked shabad (letter → lineId). Populated at lock time from
    /// ShabadCache alongside `currentShabadFLSigs`. Empty in
    /// DISCOVERING; cleared on stop().
    private var currentShabadSafeStarters: [String: String] = [:]
    /// Brief #9.19-iOS: safely-unique starter-bigram map for the
    /// currently-locked shabad. Populated at lock time from
    /// ShabadCache. Empty when not locked.
    private var currentShabadSafeBigrams: [String: String] = [:]
    /// True when ``currentLineId`` was last updated by the local FL
    /// match (not a server match). Used to detect server-overrides-FL
    /// reconciliation events for the DIAG trace. Reset to false on
    /// any server-driven line update.
    private var currentLineIdSetByFL: Bool = false
    /// Brief #9.12: Length of the most recent FL local match. Used
    /// to decide whether FL beats the server's lineId in
    /// `handleSameShabadMatchInLock`. Reset whenever the line
    /// changes via server, or on stop/reset.
    private var lastFLMatchLen: Int = 0
    /// Wall-clock timestamp of the most recent FL match attempt.
    /// Used to cooldown-throttle the FL path so it doesn't fire more
    /// than once per ``flCooldownMs`` (anti-flicker for burst partials).
    private var lastFLMatchAttemptTime: Date? = nil

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

    // ── First-letter local match (Brief #9.7) ─────────────────
    /// Minimum number of first-letters in the query before we attempt
    /// FL matching. Brief #9.10 lowered 3 → 2 so the FL path engages
    /// the moment the partial has 2 letters — enables immediate
    /// pangti-switch detection on the first two new letters.
    private static let flMinQueryLength: Int = 2
    /// Hard cap on query length to keep match cheap. The walk over
    /// the shabad's FL sigs is already O(lines), this just bounds
    /// the inner substring comparison.
    private static let flMaxQueryLength: Int = 12
    /// Cooldown between FL match attempts to prevent flicker if the
    /// server emits a burst of partials within a short window. 150 ms
    /// is well below the partial cadence (~850 ms) in practice.
    private static let flCooldownMs: Int = 150
    /// Brief #9.10-iOS: minimum length of the longest-common-substring
    /// FL match before we trust it enough to jump the highlight.
    /// Lowered 3 → 2 alongside the new generalized substring matcher
    /// so the moment 2 new pangti letters appear in the partial, we
    /// switch.
    private static let flMinMatchLength: Int = 2
    /// Brief #9.12: When local FL detects a line jump within the
    /// locked shabad with at least this much match length, FL's
    /// lineId wins over the server's per-partial lineId. Below this
    /// threshold (e.g. matchLen 2-3), FL is noisy and server wins.
    private static let flWinsOverServerMatchLen: Int = 4
    /// Brief #9.16-iOS: trailing window size for safe-unique starter scan.
    /// 3 letters covers ~1 second of speech at typical kirtan pace;
    /// long enough to catch a new pangti starter but short enough to
    /// avoid stale matches from earlier in the partial.
    static let safeStarterTrailingWindow: Int = 3
    /// Brief #9.19-iOS: trailing window size for safe-unique bigram scan.
    /// 4 letters = 3 bigrams checked, covering ~1.2s of speech at
    /// typical kirtan pace. One more than the unigram window so bigram
    /// detection has slightly wider coverage (bigrams are inherently
    /// 2-letter events and worth catching slightly earlier in the
    /// trailing slice).
    static let safeBigramTrailingWindow: Int = 4

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
        currentShabadFLSigs.removeAll(keepingCapacity: true)
        currentShabadSafeStarters.removeAll(keepingCapacity: true)
        currentShabadSafeBigrams.removeAll(keepingCapacity: true)
        currentLineIdSetByFL = false
        lastFLMatchLen = 0
        lastFLMatchAttemptTime = nil
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
        currentShabadFLSigs.removeAll(keepingCapacity: true)
        currentShabadSafeStarters.removeAll(keepingCapacity: true)
        currentShabadSafeBigrams.removeAll(keepingCapacity: true)
        currentLineIdSetByFL = false
        lastFLMatchLen = 0
        lastFLMatchAttemptTime = nil
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

        case .partial(_, let transcript, _):
            // Brief #9.7-iOS: partials drive the local FL match for
            // fast within-shabad pangti highlight. Match events
            // (server) still drive the lock state machine and any
            // cross-shabad swap detection.
            handlePartialForFLMatch(transcript: transcript)

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
        let currentId = currentShabad?.id ?? "nil"

        // Brief #9.12: Within-shabad, when FL has a strong recent local
        // match (matchLen >= threshold) and server disagrees on lineId,
        // FL wins. Server's per-partial lineId is laggy because it
        // matches against cumulative ASR text; FL detects line jumps
        // faster from its local cache of the locked shabad's FL sigs.
        if currentLineIdSetByFL
           && oldLine != lineId
           && lastFLMatchLen >= Self.flWinsOverServerMatchLen {
            NSLog("[DIAG] StreamingRaagiModeEngine FL holds over server flLineId=\(oldLine) matchLen=\(lastFLMatchLen) serverLineId=\(lineId) (FL wins, threshold=\(Self.flWinsOverServerMatchLen))")
            // Keep currentLineId = oldLine. Keep currentLineIdSetByFL = true.
            // Still update display seq so we don't go backwards.
            currentDisplaySeq = seq
            NSLog("[DIAG] StreamingRaagiModeEngine display update: FL-held same-shabad lineId=\(oldLine) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
            NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(currentId) lineId=\(oldLine) currentDisplaySeq=\(seq)")
            return
        }

        // Brief #9.7 / #9.12: below-threshold or no-FL case — server
        // wins, log the reconcile event when FL had set the line.
        if currentLineIdSetByFL && oldLine != lineId {
            NSLog("[DIAG] StreamingRaagiModeEngine FL reconcile shabadId=\(currentId) flLineId=\(oldLine) serverLineId=\(lineId) matchLen=\(lastFLMatchLen) (server wins, below threshold \(Self.flWinsOverServerMatchLen))")
        }
        currentLineId = lineId
        currentLineIdSetByFL = false  // server-driven now
        lastFLMatchLen = 0
        currentDisplaySeq = seq
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

    // MARK: - First-letter local match (Brief #9.7)

    /// Run a local first-letter match against the currently-locked
    /// shabad's pre-computed FL signatures and, if exactly one pangti
    /// matches, jump `currentLineId` to it immediately. This fires
    /// on every server partial event — typically 100s of ms BEFORE
    /// the corresponding `match` event arrives — so the highlight
    /// tracks the raagi's voice with sub-100 ms felt latency.
    ///
    /// **CRITICAL: FL match NEVER swaps shabads.** It only adjusts
    /// `currentLineId` within the currently-locked shabad. Cross-
    /// shabad swap detection stays exclusively server-driven through
    /// the #9.6 challenger logic. If the user starts singing a
    /// different shabad, FL may briefly jump to a wrong pangti in
    /// the current shabad (acceptable false positive); the server's
    /// match event for the new shabad arrives ~1 s later and
    /// challenger evidence accumulates as usual.
    ///
    /// **Sync, not async.** No actor hops, no await — all state
    /// (`currentShabadFLSigs`, `currentLineId`, `lastFLMatchAttemptTime`)
    /// lives on this @MainActor class. The FL match itself is a
    /// linear walk over ~10-50 short string arrays; trivially fast.
    private func handlePartialForFLMatch(transcript: String) {
        // Gate: LOCKED state only. DISCOVERING uses single-slot
        // pendingCandidate accumulation, not FL — the brief is
        // explicit about FL never affecting discovery.
        guard case .locked = lockState else { return }
        guard !currentShabadFLSigs.isEmpty else { return }
        if case .error = audioState { return }

        // Cooldown — anti-flicker for burst partials.
        if let last = lastFLMatchAttemptTime,
           Date().timeIntervalSince(last) * 1000 < Double(Self.flCooldownMs) {
            return
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }

        var queryFL = FirstLetterSignature.extract(trimmed)
        if queryFL.count < Self.flMinQueryLength { return }
        if queryFL.count > Self.flMaxQueryLength {
            queryFL = Array(queryFL.prefix(Self.flMaxQueryLength))
        }

        // Stamp the attempt timestamp BEFORE the walk so the
        // cooldown gates the very next partial regardless of
        // match outcome.
        lastFLMatchAttemptTime = Date()

        // Brief #9.16: Tier A — safely-unique starter fast path. If any
        // trailing letter in queryFL maps to a starter that's unique to
        // one pangti within this shabad, commit immediately. Zero false-
        // positive risk by construction (the letter doesn't appear
        // anywhere else in the shabad's FL universe).
        if !currentShabadSafeStarters.isEmpty {
            if let hit = FirstLetterSignature.findTrailingSafeUniqueStarter(
                queryFL: queryFL,
                safeStarters: currentShabadSafeStarters,
                trailingWindow: Self.safeStarterTrailingWindow
            ) {
                // Brief #9.18 fix: safe-unique is authoritative by construction
                // (the letter cannot appear in any other pangti's FL universe).
                // Always RETURN whether it's a jump to a new line or a confirm
                // of the current line — do NOT fall through to the substring
                // matcher. Falling through allowed substring to commit a wrong
                // JUMP to a different pangti while safe-unique said we're still
                // on the current line (Deep saw XLVS → 90CQ → XLVS flip-flop
                // in tati wao shabad, seq=51-53). Setting lastFLMatchLen=10 in
                // both cases preserves FL-holds-over-server behavior (#9.12
                // threshold=4, 10 leaves headroom).
                let oldLine = currentLineId ?? "nil"
                let isJump = hit.lineId != (currentLineId ?? "")
                currentLineId = hit.lineId
                currentLineIdSetByFL = true
                lastFLMatchLen = 10
                if isJump {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL unique-starter match shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) letter=\(hit.letter) partialFL='\(queryFL.joined(separator: " "))' (jumped from \(oldLine); safe-unique fast path)")
                } else {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL unique-starter confirm shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) letter=\(hit.letter) partialFL='\(queryFL.joined(separator: " "))' (safe-unique fast path, no jump)")
                }
                return
            }
        }

        // Brief #9.19: Tier B — safely-unique starter-bigram fast path. If any
        // consecutive bigram in trailing queryFL is a pangti's safely-unique
        // starter bigram (the pair appears nowhere else in the shabad), commit
        // immediately. Fires when unigram didn't (either the shabad has no
        // safely-unique unigram starters, or the current trailing has no
        // unigram hit). Same authoritative-return pattern as Tier A per #9.18.
        if !currentShabadSafeBigrams.isEmpty {
            if let hit = FirstLetterSignature.findTrailingSafeUniqueBigram(
                queryFL: queryFL,
                safeBigrams: currentShabadSafeBigrams,
                trailingWindow: Self.safeBigramTrailingWindow
            ) {
                let oldLine = currentLineId ?? "nil"
                let isJump = hit.lineId != (currentLineId ?? "")
                currentLineId = hit.lineId
                currentLineIdSetByFL = true
                lastFLMatchLen = 10
                if isJump {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL unique-bigram match shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) bigram=<\(hit.bigram.0),\(hit.bigram.1)> partialFL='\(queryFL.joined(separator: " "))' (jumped from \(oldLine); safe-unique-bigram fast path)")
                } else {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL unique-bigram confirm shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) bigram=<\(hit.bigram.0),\(hit.bigram.1)> partialFL='\(queryFL.joined(separator: " "))' (safe-unique-bigram fast path, no jump)")
                }
                return
            }
        }

        // Tier C — find longest common substring between partial FL and any pangti
        // in current shabad. See FirstLetterSignature.findBestPangti.
        let corpus: [(lineId: String, fl: [String])] = currentShabadFLSigs.map { ($0.key, $0.value) }
        let result = FirstLetterSignature.findBestPangti(
            query: queryFL,
            corpus: corpus,
            minMatchLength: Self.flMinMatchLength
        )

        let flStr = queryFL.joined(separator: " ")
        let partialHead = String(trimmed.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        let currentId = currentShabad?.id ?? "nil"

        guard let (match, runnerUp) = result else {
            // Diagnostic: compute per-pangti best matches even when no match passed threshold
            var perPangti: [String] = []
            for (lid, fl) in corpus {
                let (mlen, _, _) = FirstLetterSignature.longestSubstringMatch(query: queryFL, target: fl)
                perPangti.append("\(lid):\(mlen)/\(fl.count)")
            }
            let detail = perPangti.joined(separator: " ")
            // Brief #9.13: When FL can't find a match at all, drop FL
            // ownership so a subsequent strong server signal can take
            // over without being blocked by stale FL state.
            currentLineIdSetByFL = false
            lastFLMatchLen = 0
            NSLog("[DIAG] StreamingRaagiModeEngine FL no match shabadId=\(currentId) partial='\(partialHead)' partialFL='\(flStr)' bestPerPangti=[\(detail)] (server will detect any cross-shabad change)")
            return
        }

        let oldLine = currentLineId ?? "nil"
        let runnerStr = runnerUp.map { "\($0.lineId):\($0.matchLength)" } ?? "none"
        if match.lineId == oldLine {
            // FL-confirmed quiescent — keep latest match strength so
            // the FL-wins gate (Brief #9.12) reflects current confidence
            // rather than the first jump's strength.
            lastFLMatchLen = match.matchLength
            if match.matchLength >= Self.flWinsOverServerMatchLen {
                // Brief #9.13: When FL strongly confirms the current line,
                // claim FL ownership so the next server disagreement on
                // same shabad triggers the FL-holds defense in
                // handleSameShabadMatchInLock. Without this, FL ownership
                // is only set via the "jumped" path and is reset by every
                // server confirm — leaving FL strength purely informational.
                currentLineIdSetByFL = true
            }
            NSLog("[DIAG] StreamingRaagiModeEngine FL confirm lineId=\(match.lineId) matchLen=\(match.matchLength) qStart=\(match.queryStart) tStart=\(match.targetStart) runnerUp=\(runnerStr) partialFL='\(flStr)' ownership=\(currentLineIdSetByFL ? "FL" : "server")")
            return
        }
        if match.matchLength >= Self.flWinsOverServerMatchLen {
            // Brief #9.13: Only commit and claim FL ownership when match is
            // strong enough to defend against the next server partial.
            // Weak commits cause UI flicker because reconcile reverts them
            // ~100ms later.
            currentLineId = match.lineId
            currentLineIdSetByFL = true
            lastFLMatchLen = match.matchLength
            NSLog("[DIAG] StreamingRaagiModeEngine FL local match committed shabadId=\(currentId) lineId=\(match.lineId) matchLen=\(match.matchLength) qStart=\(match.queryStart) tStart=\(match.targetStart) runnerUp=\(runnerStr) partialFL='\(flStr)' (jumped from \(oldLine))")
        } else {
            // Brief #9.13: Weak FL jump; advisory only. Don't change
            // currentLineId/currentLineIdSetByFL — leaves UI on whatever
            // line server most recently confirmed. Still update
            // lastFLMatchLen so a strong server hold gate sees the new
            // (low) FL strength.
            lastFLMatchLen = match.matchLength
            NSLog("[DIAG] StreamingRaagiModeEngine FL local match advisory shabadId=\(currentId) lineId=\(match.lineId) matchLen=\(match.matchLength) qStart=\(match.queryStart) tStart=\(match.targetStart) runnerUp=\(runnerStr) partialFL='\(flStr)' (would-jump from \(oldLine); below commit threshold \(Self.flWinsOverServerMatchLen))")
        }
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
        // Brief #9.7: fetch shabad + FL sigs in a single actor call.
        // Brief #9.16: same call also returns safely-unique starters.
        // Brief #9.19: same call also returns safely-unique bigrams.
        let fetched: FullShabad
        let sigs: [String: [String]]
        let starters: [String: String]
        let bigrams: [String: String]
        do {
            let result = try await cache.shabadWithFLSignatures(forId: shabadId)
            fetched = result.shabad
            sigs = result.signatures
            starters = result.safeStarters
            bigrams = result.safeBigrams
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
        currentLineIdSetByFL = false  // server-driven, not FL
        currentShabadFLSigs = sigs
        currentShabadSafeStarters = starters
        currentShabadSafeBigrams = bigrams
        currentShabadRecentPeakScore = peakScore
        currentShabadRecentPeakTime = Date()
        currentDisplaySeq = seq
        pendingCandidate = nil
        // Brief #9.6: defensive — challengers should already be
        // empty in DISCOVERING (we don't touch the dict there) but
        // make sure the fresh lock starts with a clean slate.
        challengers.removeAll(keepingCapacity: true)
        lockState = .locked
        NSLog("[DIAG] StreamingRaagiModeEngine FL snapshot shabadId=\(shabadId) sigsCount=\(sigs.count)")
        // Brief #9.10-iOS: dump every pangti's FL signature so traces
        // show exactly what the matcher is working against — helps
        // diagnose any remaining FL misses (unexpected normalization,
        // weird unicode, segmentation differences vs ASR partial).
        for (lineId, fl) in sigs {
            NSLog("[DIAG] StreamingRaagiModeEngine FL pangti shabadId=\(shabadId) lineId=\(lineId) fl='\(fl.joined(separator: " "))'")
        }

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
        // Brief #9.7: fetch shabad + FL sigs together for the new
        // currentShabad. Brief #9.16/#9.19: also picks up the safely-
        // unique starter unigram + bigram maps for the new shabad.
        let fetched: FullShabad
        let sigs: [String: [String]]
        let starters: [String: String]
        let bigrams: [String: String]
        do {
            let result = try await cache.shabadWithFLSignatures(forId: shabadId)
            fetched = result.shabad
            sigs = result.signatures
            starters = result.safeStarters
            bigrams = result.safeBigrams
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
        currentLineIdSetByFL = false  // server-driven swap
        currentShabadFLSigs = sigs
        currentShabadSafeStarters = starters
        currentShabadSafeBigrams = bigrams
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
        NSLog("[DIAG] StreamingRaagiModeEngine FL snapshot shabadId=\(shabadId) sigsCount=\(sigs.count) (post-swap)")
        // Brief #9.10-iOS: dump every pangti's FL signature for the
        // new locked shabad (same diagnostic purpose as the lockTo path).
        for (lineId, fl) in sigs {
            NSLog("[DIAG] StreamingRaagiModeEngine FL pangti shabadId=\(shabadId) lineId=\(lineId) fl='\(fl.joined(separator: " "))'")
        }

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
