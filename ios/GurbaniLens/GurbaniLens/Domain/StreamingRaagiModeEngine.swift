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
    /// Brief #9.26: progressive-narrowing candidate cloud state. See
    /// ``CandidateCloudState`` in `RaagiModeViewModel.swift`. Only
    /// non-nil while singing-mode DISCOVERING has processed ≥ 5
    /// partials without a fast-lock hit. Cleared to `nil` (or set
    /// to `.hidden`) on any lock / re-lock / stop / mode toggle.
    @Published public private(set) var candidateCloud: CandidateCloudState?

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
    /// Brief #9.26 5: first-two-word starter-bigram map for the
    /// currently-locked shabad. Populated at lock time from
    /// ShabadCache. Empty when not locked. Brief #9.28: retained for
    /// diagnostic parity — Tier B2 now consumes
    /// ``currentShabadSafeFirstTwoWordSigs`` instead.
    private var currentShabadFirstTwoWordSigs: [String: String] = [:]
    /// Brief #9.28: SAFE-UNIQUE first-two-word starter-bigram map for
    /// the currently-locked shabad. Populated at lock time from
    /// ShabadCache's ``safeUniqueFirstTwoWordSigs``. Empty when not
    /// locked. Powers the FL fast-path Tier B2 in place of
    /// ``currentShabadFirstTwoWordSigs`` so a starter bigram that
    /// also appears in a neighbor pangti's body can no longer trigger
    /// a false-positive line jump.
    private var currentShabadSafeFirstTwoWordSigs: [String: String] = [:]
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

    /// Brief #9.27: FL fast-path three-gate suppressor. Composes
    /// server-confidence rejection tracking, an 800 ms debounce with a
    /// 2-partial pending-line buffer, and a line-level ping-pong guard.
    /// Only invoked while `singingModeEnabled && lockState == .locked` —
    /// speech mode and DISCOVERING skip it so pre-#9.27 behavior is
    /// byte-identical there. Reset on `start`, `stop`, and
    /// `didToggleSungMode`.
    private var flLineGate: LineFLGate = LineFLGate()

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

    /// Brief #9.20: Sung Kirtan Mode (Beta) flag. Brief #9.23d: read
    /// FRESH from UserDefaults on every access. The original #9.20
    /// design stored a snapshot at init to match the streaming/raagi
    /// flag pattern, but that produced a split-brain bug on Deep's
    /// 2026-07-05 iPhone log — session B's engine.init logged
    /// `singingMode=false` while StreamingProvider (which reads the
    /// same UserDefaults key fresh at connect) opened
    /// `?mode=sung`. Rather than trust ANY cached snapshot, this
    /// property now hits UserDefaults on every read, guaranteeing
    /// consistency with the toggle UI. `settingsSingingModeKey`
    /// centralizes the key name so accidental key drift can't recur.
    static let settingsSingingModeKey: String = "settings.singingModeEnabled"
    private var singingModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.settingsSingingModeKey)
    }
    /// Brief #9.23d: last-observed value of `singingModeEnabled`, used
    /// by ``checkSungModeToggle`` to detect user-driven changes and
    /// fire the ``didToggleSungMode`` reset. Seeded at init to the
    /// current UserDefaults value so the first observer notification
    /// doesn't spuriously fire.
    private var lastKnownSungModeEnabled: Bool
    /// Brief #9.23d: NotificationCenter token for the UserDefaults
    /// change observer. Kept so `deinit` can drop it cleanly. Fired on
    /// EVERY UserDefaults write; the observer callback compares
    /// against `lastKnownSungModeEnabled` to no-op on unrelated keys.
    private var userDefaultsObserver: NSObjectProtocol?
    /// Brief #9.23d: value of `singingModeEnabled` at the moment we
    /// called `provider.connect()` in the last `start()`. The
    /// StreamingProvider reads UserDefaults at connect time to pick
    /// `?mode=sung`; if the user toggles mid-session the server keeps
    /// running with whatever was on the handshake. We log this at
    /// toggle-change time so the trace makes the mismatch obvious.
    private var wsHandshakeSungModeAtStart: Bool?
    /// Brief #9.20: sung-mode discovery accumulator. Empty in speech
    /// mode and always empty in LOCKED. Reset on stop() and on
    /// successful lock.
    private var sungStore: SungModeAccumulatorStore

    /// Brief #9.23 Part 3 / #9.25: consecutive alaap-signal partials
    /// received while LOCKED under sung-mode. Pre-#9.25 this was
    /// incremented from the CLIENT-side observation of empty
    /// transcripts on the `.partial` stream — which never worked
    /// because the server was still emitting garbage `match` events
    /// during alaap, not empty partials. #9.25 moves detection to the
    /// server: `event=alaap` heartbeats replace the empty-partial
    /// counting, and `event=match` clears the counter. When this
    /// reaches `alaapServerEventThreshold` the engine flips into
    /// alaap state and hardens the re-lock ratio gate in `sungStore`.
    private var serverAlaapCount: Int = 0
    /// Brief #9.23 Part 3: true after `serverAlaapCount` crosses
    /// the threshold. Cleared as soon as a real match lands.
    private var alaapState: Bool = false
    /// Brief #9.25: how many consecutive server `event=alaap` events
    /// before alaap kicks in. At the streaming server's ~750 ms
    /// partial cadence, 4 covers ~3 s of sustained alaap — a real
    /// hold, not a brief gap.
    private static let alaapServerEventThreshold: Int = 4

    // MARK: - Candidate cloud (Brief #9.26)

    /// Number of partial `event=match` events consumed by the sung-
    /// mode DISCOVERING path in the current session. Reset in
    /// ``start`` / ``stop`` / ``didToggleSungMode`` and on any
    /// successful lock. Drives the fast-lock 3-partial window AND
    /// the ≥5-partial cloud-entry threshold.
    private var discoveryPartialCount: Int = 0

    /// Brief #9.26 fast-lock (Fix 1) score threshold. When
    /// ``discoveryPartialCount`` ≤ ``sungFastLockMaxPartials`` AND
    /// the incoming match has score ≥ this AND tier ≤
    /// ``sungFastLockMaxTier``, the engine LOCKS immediately —
    /// bypassing the accumulator entirely. Matches Deep's validated
    /// "clean input, high confidence" case: preserves ~90% correct
    /// wins for spoken/sung clear inputs.
    private static let sungFastLockScoreThreshold: Double = 90.0
    /// Fast-lock tier gate — tier ≤ this qualifies.
    private static let sungFastLockMaxTier: Int = 1
    /// Fast-lock partial-count gate — check applies for the first
    /// N partials of DISCOVERING only. After N partials with no
    /// fast-lock hit, we fall into the accumulator + cloud path.
    private static let sungFastLockMaxPartials: Int = 3
    /// Cloud entry threshold: after this many partials in
    /// DISCOVERING with no fast-lock or accumulator lock, publish
    /// the cloud state on every subsequent partial.
    private static let cloudEntryMinPartials: Int = 5
    /// Cloud auto-lock rule A weight ratio: top candidate must be
    /// > this × sum-of-other-visible-candidate weights.
    private static let cloudAutoLockDominanceRatio: Double = 1.5
    /// Cloud auto-lock rule A weight floor: top candidate must
    /// also have weight ≥ this.
    private static let cloudAutoLockMinWeight: Double = 100.0
    /// Cloud auto-lock rule B tier-≤1 hit count.
    private static let cloudRelaxedFastLockMinLowTierHits: Int = 3
    /// Cloud auto-lock rule B max-score gate.
    private static let cloudRelaxedFastLockMinScore: Double = 85.0

    public init(corpus: Corpus, provider: StreamingProvider) {
        self.corpus = corpus
        self.cache = ShabadCache(corpus: corpus)
        self.provider = provider
        self.mic = StreamingMicCapture()
        // Brief #9.23d: seed change-detection baseline with the same
        // fresh UserDefaults read that the computed property uses. Any
        // future divergence from this baseline (via the observer below)
        // fires `didToggleSungMode`.
        self.lastKnownSungModeEnabled = UserDefaults.standard.bool(forKey: Self.settingsSingingModeKey)
        var store = SungModeAccumulatorStore()
        // Brief #9.23 Part 4: hydrate the ambiguous-shabad set from
        // the app bundle. Missing / malformed JSON isn't fatal — the
        // accumulator just skips the multiplier (returns 1.0).
        if let ambig = Self.loadAmbiguousShabadSet() {
            store.ambiguousSet = ambig
            NSLog("[DIAG] StreamingRaagiModeEngine ambiguousSet loaded (count=\(ambig.count) threshold=\(ambig.threshold))")
        } else {
            NSLog("[DIAG] StreamingRaagiModeEngine ambiguousSet NOT loaded — multiplier inert")
        }
        self.sungStore = store
        NSLog("[DIAG] StreamingRaagiModeEngine.init singingMode=\(self.lastKnownSungModeEnabled) (fresh read)")

        // Brief #9.23d: subscribe to UserDefaults changes so a user
        // toggle mid-session fires the reset handler
        // (`didToggleSungMode`). NotificationCenter posts on any key
        // change — the observer callback compares against
        // `lastKnownSungModeEnabled` to filter out unrelated writes.
        // Delivered on `.main` queue and bridged into the actor via
        // a `Task { @MainActor in ... }` so all engine state mutations
        // stay MainActor-isolated.
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSungModeToggle()
            }
        }
    }

    deinit {
        if let obs = userDefaultsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Reactive sung-mode toggle (Brief #9.23d)

    /// Brief #9.23d: called on every UserDefaults change notification.
    /// Compares the fresh value against `lastKnownSungModeEnabled` and,
    /// on a real toggle, calls `didToggleSungMode(_:)`. Cheap enough to
    /// run on every UserDefaults write (one dict lookup + one bool
    /// compare); the observer fires often (any @AppStorage set), so
    /// this MUST early-return on unchanged values.
    private func checkSungModeToggle() {
        let now = self.singingModeEnabled
        if now == lastKnownSungModeEnabled { return }
        let old = lastKnownSungModeEnabled
        lastKnownSungModeEnabled = now
        didToggleSungMode(from: old, to: now)
    }

    /// Brief #9.23d: user toggled Sung Kirtan Mode mid-session.
    /// Resets sung-mode transient state (accumulator slots, alaap,
    /// empty-partial counter, repeat detector, alaapMode flag) so the
    /// new mode starts clean. **Does not** touch `currentShabad`,
    /// `currentLineId`, `lockState`, `challengers`, `currentDisplaySeq`,
    /// or the peak-score/time tracking — the user's visible pangti
    /// stays put through the toggle. **Does not** force a WebSocket
    /// reconnect; the server was told `mode=sung` (or not) at
    /// handshake time and continues with that window profile until
    /// the next session. When the handshake value diverges from the
    /// new toggle we log a note so the trace makes the mismatch
    /// obvious.
    private func didToggleSungMode(from old: Bool, to new: Bool) {
        let accumulatorState: String
        if new {
            accumulatorState = sungStore.slots.isEmpty ? "active-empty" : "active-\(sungStore.slots.count)-slots"
        } else {
            accumulatorState = sungStore.slots.isEmpty ? "inactive-empty" : "inactive-\(sungStore.slots.count)-slots-will-reset"
        }
        NSLog("[DIAG] StreamingRaagiModeEngine sungMode CHANGED old=\(old) new=\(new) at \(ISO8601DateFormatter().string(from: Date())) accumulator=\(accumulatorState)")
        if let handshake = wsHandshakeSungModeAtStart, handshake != new {
            NSLog("[DIAG] StreamingRaagiModeEngine mid-session sungMode toggle: WS handshake was mode=\(handshake ? "sung" : "speech"), server will not reconfigure until next session")
        }
        sungStore.reset()
        serverAlaapCount = 0
        alaapState = false
        flLineGate.reset()
        // Brief #9.26: any mode-toggle wipes the transient cloud +
        // partial counter — a switch from speech ↔ sung shouldn't
        // leave a stale cloud on screen or a partial count from the
        // previous mode.
        discoveryPartialCount = 0
        dismissCandidateCloud(reason: "sungModeToggle")
    }

    // MARK: - Effective-lineId resolver (Brief #9.24 Part 7)

    /// Return the given triggering lineId if the shabad's display
    /// body contains it, else fall back to the first display line.
    /// Logs a DIAG line on fallback because it's a surprising path —
    /// after the Part-7 Manglacharan inclusion, this should be rare.
    private static func resolveEffectiveLineId(_ triggeringLineId: String, in shabad: FullShabad) -> String {
        if shabad.lines.contains(where: { $0.id == triggeringLineId }) {
            return triggeringLineId
        }
        if let first = shabad.lines.first {
            NSLog("[DIAG] StreamingRaagiModeEngine anchor fallback shabadId=\(shabad.id) triggeringLineId=\(triggeringLineId) not in display body — anchoring to first line \(first.id)")
            return first.id
        }
        NSLog("[DIAG] StreamingRaagiModeEngine anchor fallback shabadId=\(shabad.id) — shabad has no display lines")
        return triggeringLineId
    }

    // MARK: - Ambiguous-shabad set loader (Brief #9.23 Part 4)

    private static func loadAmbiguousShabadSet() -> AmbiguousShabadSet? {
        guard let url = Bundle.main.url(forResource: "ambiguous_shabads", withExtension: "json") else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return try AmbiguousShabadSet.load(fromJSON: data)
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine ambiguous_shabads.json parse failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Public lifecycle

    public func start() {
        if eventTask != nil {
            NSLog("[DIAG] StreamingRaagiModeEngine.start ignored — already running")
            return
        }
        NSLog("[DIAG] StreamingRaagiModeEngine.start (state=discovering)")
        // Brief #9.23d: re-sync the change-detection baseline with a
        // fresh read; a toggle that happened while the engine was
        // stopped won't fire the observer's diff, but the next
        // `checkSungModeToggle` should treat the current value as the
        // baseline (not the value from the prior session).
        let sungAtStart = self.singingModeEnabled
        lastKnownSungModeEnabled = sungAtStart
        wsHandshakeSungModeAtStart = sungAtStart
        NSLog("[DIAG] StreamingRaagiModeEngine sungMode=\(sungAtStart) at start (fresh read)")
        setAudioState(.listening)
        bufferEnergy = 0
        activeJaikara = nil
        currentDisplaySeq = 0
        currentShabadRecentPeakScore = 0
        currentShabadRecentPeakTime = nil
        currentShabadFLSigs.removeAll(keepingCapacity: true)
        currentShabadSafeStarters.removeAll(keepingCapacity: true)
        currentShabadSafeBigrams.removeAll(keepingCapacity: true)
        currentShabadFirstTwoWordSigs.removeAll(keepingCapacity: true)
        currentShabadSafeFirstTwoWordSigs.removeAll(keepingCapacity: true)
        currentLineIdSetByFL = false
        lastFLMatchLen = 0
        lastFLMatchAttemptTime = nil
        sungStore.reset()
        serverAlaapCount = 0
        alaapState = false
        flLineGate.reset()
        lockState = .discovering
        pendingCandidate = nil
        challengers.removeAll(keepingCapacity: true)
        // Brief #9.26: reset cloud state + partial counter each session.
        discoveryPartialCount = 0
        candidateCloud = nil
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
        currentShabadFirstTwoWordSigs.removeAll(keepingCapacity: true)
        currentShabadSafeFirstTwoWordSigs.removeAll(keepingCapacity: true)
        currentLineIdSetByFL = false
        lastFLMatchLen = 0
        lastFLMatchAttemptTime = nil
        lockState = .discovering
        pendingCandidate = nil
        challengers.removeAll(keepingCapacity: true)
        sungStore.reset()
        serverAlaapCount = 0
        alaapState = false
        flLineGate.reset()
        // Brief #9.26: teardown drops any lingering cloud state so the
        // next session starts from a clean slate.
        discoveryPartialCount = 0
        candidateCloud = nil
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

        case .partial(let seq, let transcript, _):
            // Brief #9.7-iOS: partials drive the local FL match for
            // fast within-shabad pangti highlight. Match events
            // (server) still drive the lock state machine and any
            // cross-shabad swap detection. Brief #9.25 removes the
            // client-side empty-partial alaap counter from this path
            // — server-driven `event=alaap` is now the source of
            // truth (server never emitted empty partials during
            // alaap; the client counter never fired). Brief #9.27:
            // seq threaded so the FL walk can check the server-
            // rejection cache before running.
            handlePartialForFLMatch(transcript: transcript, seq: seq)

        case .match(let seq, let shabadId, let lineId, let score, let tier, _, _):
            // Brief #9.25: a real match clears any server-driven
            // alaap accumulation. If we were in alaap, drop out of
            // it and revert the sungStore re-lock ratio.
            resetAlaapOnRealMatch(reason: "match")
            await handleMatch(seq: seq, shabadId: shabadId, lineId: lineId, score: score, tier: tier)

        case .jaikara(_, let phrase):
            // Jaikara is a banner overlay; doesn't disturb lock or
            // challenger. Pass through unchanged (Brief #9.4 constraint).
            showJaikara(phrase)

        case .noMatch(let seq, let reason, _):
            NSLog("[DIAG] StreamingRaagiModeEngine no_match seq=\(seq) reason=\(reason)")

        case .alaap(let seq, let reason, let partialLen, _):
            // Brief #9.25: server observed a degenerate ASR partial
            // (whitespace / vowel-only / repeat-tokens / repeat-
            // bigram) and suppressed the matcher cascade. Do NOT
            // touch accumulator, current shabad, or peek state.
            // Increment `serverAlaapCount`; once it crosses the
            // threshold, flip into alaap state so the sung-mode
            // re-lock ratio gate tightens from 1.5× to 2.0×.
            // Brief #9.27: record the rejection into the FL gate so
            // any late-arriving partial for the same seq skips its
            // FL walk entirely.
            if singingModeEnabled, case .locked = lockState {
                flLineGate.recordServerRejection(seq: seq, reason: .alaap)
            }
            handleServerAlaap(seq: seq, reason: reason, partialLen: partialLen)

        case .noConfidentMatch(let seq, let reason, let top1Score, let top1Tier, _):
            // Brief #9.25: server matcher accepted a candidate but
            // sung-mode confidence gate blocked emission. Diagnostic
            // only — no state mutation. Do NOT reset alaap state
            // (this is not a real match, it's the server telling us
            // it explicitly refused to emit one).
            // Brief #9.27: record the rejection so the FL walk on
            // any late-arriving partial for the same seq skips.
            if singingModeEnabled, case .locked = lockState {
                flLineGate.recordServerRejection(seq: seq, reason: .noConfidentMatch)
            }
            NSLog("[DIAG] StreamingRaagiModeEngine event=no_confident_match seq=\(seq) top1_score=\(String(format: "%.1f", top1Score)) top1_tier=\(top1Tier) reason=\(reason)")

        case .disconnected(let reason):
            NSLog("[DIAG] StreamingRaagiModeEngine disconnected reason=\(reason)")
            setAudioState(.error("disconnected — reconnecting…"))
        }
    }

    // MARK: - Server-driven alaap (Brief #9.25)

    /// Increment the server-alaap counter; once it crosses the
    /// threshold, flip alaap state on and tighten `sungStore`'s
    /// re-lock ratio. Only meaningful under sung-mode + LOCKED —
    /// discovery has no lock to defend, speech mode never receives
    /// `event=alaap`.
    private func handleServerAlaap(seq: Int, reason: String, partialLen: Int) {
        // Brief #9.23e Fix 1: unconditional entry DIAG. Deep's post-#9.25
        // iPhone log had ZERO `event=alaap` DIAGs despite server logs
        // showing 40+ `alaap suppression: too_short` firings. Two silent
        // paths in the prior code hid whether we reached this handler at
        // all: (a) `guard singingModeEnabled else { return }` returned
        // without logging; (b) if StreamingProvider itself never received
        // `type: "alaap"` we'd have no client-side breadcrumb either.
        // This entry line fires before both guards so future traces
        // definitively distinguish "engine never called" (silent → server
        // is the culprit) from "engine called but gated" (this line
        // present → check state / sung flag). Cost is one NSLog per
        // server-side alaap event — matches the cadence of other event
        // handlers and is bounded by the server's own alaap suppression.
        NSLog("[DIAG] StreamingRaagiModeEngine event=alaap ENTRY seq=\(seq) reason=\(reason) partialLen=\(partialLen) lockState=\(lockState) singingModeEnabled=\(singingModeEnabled)")
        guard singingModeEnabled else { return }
        guard case .locked = lockState else {
            NSLog("[DIAG] StreamingRaagiModeEngine event=alaap ignored (state=\(lockState)) seq=\(seq) reason=\(reason)")
            return
        }
        serverAlaapCount += 1
        if serverAlaapCount >= Self.alaapServerEventThreshold, !alaapState {
            alaapState = true
            sungStore.alaapMode = true
            NSLog("[DIAG] StreamingRaagiModeEngine event=alaap serverAlaapCount=\(serverAlaapCount) alaapState=true reason=\(reason) partialLen=\(partialLen) — re-lock ratio → \(SungModeAccumulatorStore.alaapReLockRatio)")
        } else {
            NSLog("[DIAG] StreamingRaagiModeEngine event=alaap serverAlaapCount=\(serverAlaapCount) alaapState=\(alaapState) reason=\(reason) partialLen=\(partialLen)")
        }
    }

    /// Called on any real `event=match`. Resets the server-alaap
    /// counter and, if we were in alaap, drops back out of it.
    private func resetAlaapOnRealMatch(reason: String) {
        if serverAlaapCount != 0 || alaapState {
            let wasAlaap = alaapState
            serverAlaapCount = 0
            if wasAlaap {
                alaapState = false
                sungStore.alaapMode = false
                NSLog("[DIAG] StreamingRaagiModeEngine alaapState=false (\(reason) resumed; re-lock ratio → \(SungModeAccumulatorStore.lockRatio))")
            }
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
        // Brief #9.23d: log a fresh read of the toggle at every match
        // so the trace shows whether sung-mode gates are firing as
        // expected. Cheap (one UserDefaults dict lookup); noisy but
        // essential — this line is the smoking gun for the split-brain
        // toggle bug Deep hit on 2026-07-05.
        let sungNow = self.singingModeEnabled
        NSLog("[DIAG] StreamingRaagiModeEngine handleMatch sungModeEnabled=\(sungNow) seq=\(seq) shabadId=\(shabadId) tier=\(tier) score=\(String(format: "%.1f", score))")
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
        // Brief #9.20: sung-mode discovery path. When the flag is on,
        // route the match through the decaying multi-slot accumulator
        // and skip the speech-mode pendingCandidate path entirely.
        // Perfect isolation between the two modes — speech behavior is
        // byte-for-byte unchanged when singingModeEnabled is false.
        //
        // Brief #9.23b: this early return is ALSO the initial-lock
        // suppression for the legacy fast-lock (score ≥ 95) and
        // 2-hit evidence-lock (score ≥ 80) branches below. Under
        // sung-mode ON, the accumulator's `.lock` decision (→
        // `lockTo(via:"sungAcc")`) is the ONLY authorized initial-
        // lock path. Do not remove this gate without also gating
        // the two `lockTo(via:)` sites below.
        if singingModeEnabled {
            await handleSungModeDiscoveringMatch(
                shabadId: shabadId,
                lineId: lineId,
                score: score,
                tier: tier,
                seq: seq
            )
            return
        }

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

    /// Brief #9.20: sung-mode DISCOVERING match handler. Thin wrapper
    /// over `SungModeAccumulatorStore.processMatch(...)`. Routes the
    /// event to the accumulator, logs the outcome, and if the store
    /// declares a lock, invokes the same `lockTo(...)` path as the
    /// speech-mode fast/evidence branches.
    ///
    /// Precondition: caller has verified `singingModeEnabled == true`
    /// and state == .discovering. Score/tier come from the server
    /// event.
    private func handleSungModeDiscoveringMatch(
        shabadId: String,
        lineId: String,
        score: Double,
        tier: Int,
        seq: Int
    ) async {
        // Brief #9.26 Fix 1: count every ingest-eligible partial
        // (post tier-3 filter runs below, but the partial-counter
        // ticks unconditionally so the fast-lock 3-partial window is
        // measured in server events, not accumulator ingests). The
        // counter drives BOTH the fast-lock 3-partial window AND
        // the ≥5-partial cloud-entry threshold.
        discoveryPartialCount += 1

        // Brief #9.26 Fix 1: FAST-LOCK path. Deep validated ~90%
        // correct on clean spoken/sung inputs — the accumulator's
        // "wait for 3 hits" + weight threshold pathway is
        // deliberately preserved for uncertain inputs and DELIBERATELY
        // bypassed here so clean-input latency stays at one partial.
        // Rule: within the first `sungFastLockMaxPartials` server
        // matches, any hit with score ≥ 90 AND tier ≤ 1 → LOCK
        // immediately, no cloud. The `if` order guarantees this
        // check fires BEFORE tier-3 filter or accumulator ingest,
        // so a legitimate clean tier-0/1 hit at 90+ can never be
        // masked by later noise.
        if discoveryPartialCount <= Self.sungFastLockMaxPartials
            && score >= Self.sungFastLockScoreThreshold
            && tier <= Self.sungFastLockMaxTier {
            NSLog("[DIAG] StreamingRaagiModeEngine sungMode FAST-LOCK shabadId=\(shabadId) partial=\(discoveryPartialCount) score=\(String(format: "%.1f", score)) tier=\(tier) via=sungFast")
            await lockTo(shabadId: shabadId, lineId: lineId, peakScore: score, via: "sungFast", seq: seq, tier: tier)
            sungStore.capWeight(shabadId: shabadId)
            return
        }

        // Brief #9.22 Fix 3: skip tier-3 hits in sung-mode DISCOVERY.
        // Tier-3 is full-SGGS regex noise; during noisy sung audio it
        // scatters across many candidates and delays lock (Deep saw
        // first shabad take 55 s / 126 partials before crossing the
        // weight threshold). Post-lock (`handleSameShabadMatchInLock`
        // + `handleDifferentShabadMatchInLock`) still consumes tier-3
        // for current-shabad weight refresh during quieter passages.
        if tier > 2 {
            NSLog("[DIAG] StreamingRaagiModeEngine sungMode discovery tier-3 skip seq=\(seq) shabadId=\(shabadId) score=\(String(format: "%.1f", score))")
            return
        }
        NSLog("[DIAG] SungModeAccumulator.processMatch sungModeEnabled=\(self.singingModeEnabled) shabadId=\(shabadId) score=\(String(format: "%.1f", score)) tier=\(tier) seq=\(seq)")
        let decision = sungStore.processMatch(shabadId: shabadId, score: score, tier: tier, lineId: lineId)
        // Diagnostic: computed weight contribution for this event.
        // Matches the brief's suggested log format.
        let tierClamped = max(0, min(tier, SungModeAccumulatorStore.tierMultiplier.count - 1))
        let addedWeight = score >= SungModeAccumulatorStore.minScore
            ? score * SungModeAccumulatorStore.tierMultiplier[tierClamped]
            : 0
        switch decision {
        case .noLock(let top3Summary, let slotCount):
            NSLog("[DIAG] StreamingRaagiModeEngine sungMode accumulator seq=\(seq) added \(shabadId) tier=\(tierClamped) score=\(String(format: "%.1f", score)) weight+=\(String(format: "%.1f", addedWeight)) → top3=[\(top3Summary)] slotCount=\(slotCount)")
            // Brief #9.26 Fix 1: after ≥5 partials with no fast-lock
            // or accumulator lock, engage the candidate-cloud UX.
            // The update helper computes the top-N via the accumulator,
            // enriches each row with ang via ShabadCache, publishes
            // state to the UI, and then checks the auto-lock rules.
            if discoveryPartialCount >= Self.cloudEntryMinPartials {
                await updateCandidateCloud(seq: seq, tier: tier)
            }
        case .lock(let topId, let peakScore, let weight, let hitCount, let runnerUpWeight, let tiers):
            NSLog("[DIAG] StreamingRaagiModeEngine sungMode LOCK shabadId=\(topId) weight=\(String(format: "%.1f", weight)) hits=\(hitCount) runnerUpWeight=\(String(format: "%.1f", runnerUpWeight)) peakScore=\(String(format: "%.1f", peakScore)) tiers=\(tiers)")
            await lockTo(shabadId: topId, lineId: lineId, peakScore: peakScore, via: "sungAcc", seq: seq, tier: tier)
            // Brief #9.21: keep the accumulator running post-lock so
            // cross-shabad matches can build re-lock evidence. Cap
            // the winner's weight to `lockWeightThreshold` (100) so
            // pre-lock overkill weight (e.g. 146) doesn't make the
            // NEXT re-lock require an impossibly-large challenger.
            sungStore.capWeight(shabadId: topId)
        }
    }

    // MARK: - Candidate cloud publish + auto-lock (Brief #9.26)

    /// Brief #9.26 Fix 1: recompute the top-N candidate rows from the
    /// sung accumulator, enrich each row with `ang` via ShabadCache,
    /// publish the resulting `.visible(...)` cloud state to the UI,
    /// and evaluate the two auto-lock rules. Called after each
    /// DISCOVERING partial once ``discoveryPartialCount`` has crossed
    /// ``cloudEntryMinPartials``.
    ///
    /// Ang lookup: `cache.shabad(forId:)` is memoized inside the
    /// actor, so the N ≤ 8 fetches per partial are cheap after the
    /// first partial in a session. Best-effort — a fetch failure
    /// leaves that row's `ang = 0`, which the UI renders as "Ang —".
    private func updateCandidateCloud(seq: Int, tier: Int) async {
        let rawRows = sungStore.topCandidates(maxCount: 8)
        guard !rawRows.isEmpty else { return }
        var enriched: [SungModeAccumulatorStore.CandidateRow] = []
        enriched.reserveCapacity(rawRows.count)
        for row in rawRows {
            var angForRow = 0
            do {
                let shabad = try await cache.shabad(forId: row.shabadId)
                // Prefer the matched line's ang, fall back to the
                // shabad's first display line.
                if let matched = shabad.lines.first(where: { $0.id == row.matchedLineId }) {
                    angForRow = matched.ang
                } else if let first = shabad.lines.first {
                    angForRow = first.ang
                }
            } catch {
                NSLog("[DIAG] StreamingRaagiModeEngine cloud ang fetch failed shabadId=\(row.shabadId): \(error.localizedDescription)")
            }
            enriched.append(SungModeAccumulatorStore.CandidateRow(
                shabadId: row.shabadId,
                ang: angForRow,
                matchedLineId: row.matchedLineId,
                maxScoreSeen: row.maxScoreSeen,
                weight: row.weight,
                hits: row.hits
            ))
        }
        let previous = candidateCloud
        let newState: CandidateCloudState = .visible(rows: enriched, partialsSeen: discoveryPartialCount)
        candidateCloud = newState
        if previous != newState {
            NSLog("[DIAG] StreamingRaagiModeEngine cloud STATE change: partials=\(discoveryPartialCount) candidates=\(enriched.count) top=\(enriched.first?.shabadId ?? "nil")")
        }

        // Auto-lock evaluation.
        guard let top = enriched.first else { return }
        let sumOthers = enriched.dropFirst().reduce(0.0) { $0 + $1.weight }
        let ruleA = top.weight > sumOthers * Self.cloudAutoLockDominanceRatio
            && top.weight >= Self.cloudAutoLockMinWeight
        // Rule B pulls tier info directly from the accumulator slot.
        let lowTierHits = sungStore.slots[top.shabadId]?.lastTiers.filter { $0 <= 1 }.count ?? 0
        let ruleB = lowTierHits >= Self.cloudRelaxedFastLockMinLowTierHits
            && top.maxScoreSeen >= Self.cloudRelaxedFastLockMinScore
        if ruleA || ruleB {
            let ruleTag = ruleA ? "dominance" : "relaxedFast"
            NSLog("[DIAG] StreamingRaagiModeEngine cloud AUTO-LOCK top=\(top.shabadId) topWeight=\(String(format: "%.1f", top.weight)) sumOthers=\(String(format: "%.1f", sumOthers)) rule=\(ruleTag) via=cloudAuto")
            await performCloudLock(
                shabadId: top.shabadId,
                lineId: top.matchedLineId,
                peakScore: top.maxScoreSeen,
                via: "cloudAuto",
                seq: seq,
                tier: tier
            )
        }
    }

    /// Brief #9.26 Fix 1: shared lock helper for the cloud auto-lock
    /// and force-lock paths. Dismisses the cloud, calls the standard
    /// ``lockTo`` pathway (which handles ShabadCache + FL sig
    /// snapshot + state transition), and caps the winner's weight.
    private func performCloudLock(
        shabadId: String,
        lineId: String,
        peakScore: Double,
        via: String,
        seq: Int,
        tier: Int
    ) async {
        candidateCloud = .hidden
        await lockTo(shabadId: shabadId, lineId: lineId, peakScore: peakScore, via: via, seq: seq, tier: tier)
        sungStore.capWeight(shabadId: shabadId)
    }

    /// Brief #9.26 Fix 1: user tapped a candidate row in the cloud
    /// UX. Immediately locks to the tapped shabad using the row's
    /// last-observed `matchedLineId` as the highlight anchor.
    /// Guarded: only fires while state == .discovering AND the
    /// cloud is currently .visible. Emitted DIAG logs the manual
    /// origin so the trace is unambiguous.
    public func forceLockFromCloud(shabadId: String, matchedLineId: String) async {
        guard case .discovering = lockState else {
            NSLog("[DIAG] StreamingRaagiModeEngine cloud FORCE-LOCK ignored — state=\(lockState) shabadId=\(shabadId)")
            return
        }
        NSLog("[DIAG] StreamingRaagiModeEngine cloud FORCE-LOCK from user tap shabadId=\(shabadId) lineId=\(matchedLineId) via=cloudManual")
        let peak = sungStore.slots[shabadId]?.maxScoreSeen ?? Self.sungFastLockScoreThreshold
        // seq: use currentDisplaySeq so the stale-check inside
        // lockTo (`seq < currentDisplaySeq`) passes. During discovery
        // currentDisplaySeq is still 0 (never wrote a match to the
        // display); subsequent server matches at higher seq will win
        // normally.
        await performCloudLock(
            shabadId: shabadId,
            lineId: matchedLineId,
            peakScore: peak,
            via: "cloudManual",
            seq: currentDisplaySeq,
            tier: 1
        )
    }

    /// Brief #9.26: dismiss the candidate cloud with a diagnostic
    /// reason. Called on lock/re-lock/stop/mode-toggle paths that
    /// need to make sure the cloud isn't left stale on-screen.
    /// Emits a DIAG only when the state actually changes.
    private func dismissCandidateCloud(reason: String) {
        if candidateCloud == nil || candidateCloud == .hidden { return }
        NSLog("[DIAG] StreamingRaagiModeEngine cloud DISMISS reason=\(reason)")
        candidateCloud = .hidden
    }

    /// Brief #9.26: fetch the display Gurmukhi text for a pangti in
    /// a candidate shabad. Called by the cloud UX to preview each
    /// row's matched-pangti. Prefers `gurmukhiUnicode`, falls back
    /// to AnmolLipi conversion — same policy as `RaagiView.rowGurmukhi`.
    public func fetchPangtiText(shabadId: String, lineId: String) async -> String? {
        do {
            let shabad = try await cache.shabad(forId: shabadId)
            guard let line = shabad.lines.first(where: { $0.id == lineId }) else { return nil }
            if let uni = line.gurmukhiUnicode, !uni.isEmpty {
                return uni
            }
            return Gurmukhi.fromAnmolLipi(line.gurmukhi)
        } catch {
            return nil
        }
    }

    /// Brief #9.21: sung-mode cross-shabad re-lock. Called from
    /// `handleDifferentShabadMatchInLock` when the accumulator
    /// declares a new leader has crossed all three re-lock gates.
    /// Clears speech-mode challenger state (built up under the old
    /// currentShabad and now stale), reuses the existing
    /// `lockTo(...)` pathway so all downstream side effects (FL
    /// snapshot swap, `currentShabad`/`currentLineId` reset,
    /// `currentDisplaySeq`, sticky-display log, UI update) fire
    /// identically to a fresh discovery lock. Caps the new
    /// winner's accumulator weight so subsequent re-locks stay
    /// achievable.
    private func performSungModeReLock(
        shabadId: String,
        lineId: String,
        peakScore: Double,
        seq: Int,
        tier: Int
    ) async {
        challengers.removeAll()
        await lockTo(shabadId: shabadId, lineId: lineId, peakScore: peakScore, via: "sungReLock", seq: seq, tier: tier)
        sungStore.capWeight(shabadId: shabadId)
    }

    // ── LOCKED + same shabad ──────────────────────────────────────

    private func handleSameShabadMatchInLock(
        seq: Int,
        lineId: String,
        score: Double,
        tier: Int
    ) {
        // Brief #9.21: refresh sung-mode accumulator with the same-
        // shabad hit so its weight doesn't decay unfairly against
        // future cross-shabad challengers. Same-shabad can never
        // trigger reLock by definition (leader IS current), so we
        // ignore the decision and just log the diagnostic.
        if singingModeEnabled, let currentId = currentShabad?.id {
            NSLog("[DIAG] SungModeAccumulator.processMatchInLocked sungModeEnabled=true same-shabad shabadId=\(currentId) score=\(String(format: "%.1f", score)) tier=\(tier) seq=\(seq)")
            let decision = sungStore.processMatchInLocked(
                shabadId: currentId, score: score, tier: tier, currentShabadId: currentId, lineId: lineId
            )
            if case .noSwap(let top3Summary, let slotCount, let currentWeight) = decision {
                NSLog("[DIAG] StreamingRaagiModeEngine sungMode locked-acc seq=\(seq) same-shabad \(currentId) tier=\(tier) score=\(String(format: "%.1f", score)) → current:\(String(format: "%.1f", currentWeight)) top3=[\(top3Summary)] slotCount=\(slotCount)")
            }
        }

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
        // Brief #9.21: sung-mode cross-shabad path. When the flag is
        // on, feed the incoming match into the LOCKED-state
        // accumulator. On .noSwap we still fall through to the
        // speech-mode challenger logic below (harmless — the score
        // < 70 floor filters out most sung matches; leaves the rare
        // high-score short-circuit intact). On .reLock we swap
        // shabads directly and return.
        if singingModeEnabled, let currentId = currentShabad?.id {
            NSLog("[DIAG] SungModeAccumulator.processMatchInLocked sungModeEnabled=true cross-shabad shabadId=\(shabadId) currentShabad=\(currentId) score=\(String(format: "%.1f", score)) tier=\(tier) seq=\(seq)")
            let decision = sungStore.processMatchInLocked(
                shabadId: shabadId, score: score, tier: tier, currentShabadId: currentId, lineId: lineId
            )
            switch decision {
            case .noSwap(let top3Summary, let slotCount, let currentWeight):
                NSLog("[DIAG] StreamingRaagiModeEngine sungMode locked-acc seq=\(seq) cross-shabad \(shabadId) tier=\(tier) score=\(String(format: "%.1f", score)) → current:\(String(format: "%.1f", currentWeight)) top3=[\(top3Summary)] slotCount=\(slotCount)")
                // fall through to speech-mode challenger logic below
            case .reLock(let topId, let peakScore, let weight, let hitCount, let currentWeight, let tiers):
                let ratio = currentWeight > 0 ? weight / currentWeight : Double.infinity
                NSLog("[DIAG] StreamingRaagiModeEngine sungMode RE-LOCK from=\(currentId) to=\(topId) currentWeight=\(String(format: "%.1f", currentWeight)) challengerWeight=\(String(format: "%.1f", weight)) ratio=\(String(format: "%.2f", ratio)) hits=\(hitCount) tiers=\(tiers)")
                await performSungModeReLock(shabadId: topId, lineId: lineId, peakScore: peakScore, seq: seq, tier: tier)
                return
            }
        }

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

        // Brief #9.23b: sung-mode owns cross-shabad re-lock. The
        // legacy speech-mode evidence/bypass path picks a winner
        // after just 2 challenger matches at score ≥ 75 (evidence)
        // or a single match ≥ 92 (bypass) — that bypasses ALL five
        // sung-mode re-lock gates (weight ≥ 100, ratio ≥ 1.5×
        // current, hits ≥ 4, recency ≤ 3 s, ≥ 2 tier-0/1 hits).
        // Deep's #9.23a iPhone log had
        //     SWAP from=HLD to=6V0 via=evidence
        //     challengerMatches=2 latestScore=81.0
        // firing while the accumulator correctly said .noSwap — a
        // toggle-isolation leak. Under sung-mode we log the
        // suppression and return; the accumulator's
        // `performSungModeReLock` (fired above via .reLock) is the
        // ONLY authorized cross-shabad swap path when
        // singingModeEnabled == true. Challenger tracking + the
        // `challenger …` DIAG snapshot above still fire so we
        // retain visibility into what the legacy path would have
        // done.
        if singingModeEnabled {
            NSLog("[DIAG] StreamingRaagiModeEngine evidence-swap SUPPRESSED (sungMode owns lock/re-lock, shabadId=\(winner.entry.shabadId) matches=\(winner.entry.matchCount) latestScore=\(String(format: "%.1f", winner.entry.latestScore)) via=\(winner.via))")
            return
        }

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
    private func handlePartialForFLMatch(transcript: String, seq: Int) {
        // Gate: LOCKED state only. DISCOVERING uses single-slot
        // pendingCandidate accumulation, not FL — the brief is
        // explicit about FL never affecting discovery.
        guard case .locked = lockState else { return }
        guard !currentShabadFLSigs.isEmpty else { return }
        if case .error = audioState { return }

        // Brief #9.27: server-confidence gate. If the server has
        // already rejected this partial's seq as `no_confident_match`
        // or `alaap`, suppress the entire FL walk with a single DIAG
        // line. Only applies under sung-mode; speech-mode FL is
        // byte-identical to HEAD `4a1bd00`.
        if singingModeEnabled, flLineGate.isServerRejected(seq: seq) {
            let reason = flLineGate.serverRejectionReason(seq: seq)?.rawValue ?? "unknown"
            NSLog("[DIAG] StreamingRaagiModeEngine FL SUPPRESSED (server-rejected seq=\(seq) reason=\(reason))")
            return
        }

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
                let currentLineSafe = currentLineId ?? ""
                let isJump = hit.lineId != currentLineSafe
                // Brief #9.27: debounce + line ping-pong gate for jumps only.
                if isJump, !flLineGateAllowsChange(from: currentLineSafe, to: hit.lineId, seq: seq) {
                    return
                }
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
                let currentLineSafe = currentLineId ?? ""
                let isJump = hit.lineId != currentLineSafe
                if isJump, !flLineGateAllowsChange(from: currentLineSafe, to: hit.lineId, seq: seq) {
                    return
                }
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

        // Brief #9.26 5 / #9.28: Tier B2 — first-two-word signature
        // fast path. Fires when a pangti's clean opening two-word FL
        // signature appears as a consecutive bigram in the ASR partial's
        // trailing window AND that starter bigram carries the
        // zero-false-positive-within-shabad guarantee restored by
        // #9.28: unique among starters AND absent from every other
        // pangti's FL body. Structurally overlaps with Tier B (safe-
        // unique bigram starter) — kept as a separate call site so a
        // future divergence in the two safe-unique criteria is
        // possible without re-plumbing.
        if !currentShabadSafeFirstTwoWordSigs.isEmpty {
            if let hit = FirstLetterSignature.findTrailingFirstTwoWordSig(
                queryFL: queryFL,
                firstTwoWordSigs: currentShabadSafeFirstTwoWordSigs,
                trailingWindow: Self.safeBigramTrailingWindow
            ) {
                let oldLine = currentLineId ?? "nil"
                let currentLineSafe = currentLineId ?? ""
                let isJump = hit.lineId != currentLineSafe
                if isJump, !flLineGateAllowsChange(from: currentLineSafe, to: hit.lineId, seq: seq) {
                    return
                }
                currentLineId = hit.lineId
                currentLineIdSetByFL = true
                lastFLMatchLen = 10
                if isJump {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL first-2-word match shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) bigram=<\(hit.bigram.0),\(hit.bigram.1)> partialFL='\(queryFL.joined(separator: " "))' (jumped from \(oldLine); first-2-word fast path)")
                } else {
                    NSLog("[DIAG] StreamingRaagiModeEngine FL first-2-word confirm shabadId=\(currentShabad?.id ?? "nil") lineId=\(hit.lineId) bigram=<\(hit.bigram.0),\(hit.bigram.1)> partialFL='\(queryFL.joined(separator: " "))' (first-2-word fast path, no jump)")
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
            // ~100ms later. Brief #9.27: debounce + line ping-pong gate.
            if !flLineGateAllowsChange(from: currentLineId ?? "", to: match.lineId, seq: seq) {
                return
            }
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

    /// Brief #9.27: intercept FL-proposed line CHANGES (not confirms)
    /// with the ``LineFLGate`` debounce + line ping-pong throttles.
    /// Returns `true` when the caller should proceed with the assignment,
    /// `false` when the gate blocked the change (a DIAG line is logged
    /// inside the blocked branch so callers do not need to duplicate it).
    ///
    /// Speech mode (singingModeEnabled = false) and DISCOVERING short-
    /// circuit to `true` so pre-#9.27 behavior stays byte-identical
    /// outside the LOCKED sung-mode path.
    private func flLineGateAllowsChange(from oldLine: String, to newLine: String, seq: Int) -> Bool {
        guard singingModeEnabled, case .locked = lockState else { return true }
        let d = flLineGate.decideLineChange(
            currentLine: oldLine, proposedLine: newLine, seq: seq, now: Date()
        )
        switch d {
        case .allow:
            return true
        case .suppressedByServerRejection(let s, let reason):
            NSLog("[DIAG] StreamingRaagiModeEngine FL SUPPRESSED (server-rejected seq=\(s) reason=\(reason))")
            return false
        case .debounced(let ms, let line):
            NSLog("[DIAG] StreamingRaagiModeEngine FL DEBOUNCED (msSinceLastChange=\(ms) line=\(line))")
            return false
        case .pingPongDenied(let a, let b, let count):
            // Gate emits the one-time "DETECTED" log at threshold-cross;
            // this engine-side line fires on every blocked attempt so the
            // trace records which specific proposal got denied.
            NSLog("[DIAG] StreamingRaagiModeEngine FL DENIED (line ping-pong pair=\(a)↔\(b) swapCount=\(count) currentLine=\(oldLine) proposed=\(newLine))")
            return false
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
        // Brief #9.26 5: same call now also returns first-two-word sigs.
        // Brief #9.28: same call also returns SAFE-UNIQUE first-two-
        // word sigs — the map Tier B2 consumes.
        let fetched: FullShabad
        let sigs: [String: [String]]
        let starters: [String: String]
        let bigrams: [String: String]
        let firstTwo: [String: String]
        let safeFirstTwo: [String: String]
        do {
            let result = try await cache.shabadWithFLSignatures(forId: shabadId)
            fetched = result.shabad
            sigs = result.signatures
            starters = result.safeStarters
            bigrams = result.safeBigrams
            firstTwo = result.firstTwoWordSigs
            safeFirstTwo = result.safeFirstTwoWordSigs
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine lock fetch failed shabadId=\(shabadId): \(error.localizedDescription) — staying in DISCOVERING")
            return
        }
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch-lock)")
            return
        }

        // Brief #9.24 Part 7: anchor the visible pangti to the line
        // that actually triggered the lock. `lineId` is the server
        // match's line — Manglacharan lines are now included in
        // `fetched.lines`, so the highlight lands on Mool Mantar when
        // that's where the raagi began. Defensive fallback to the
        // first display line covers the rare case of a triggering
        // line that isn't in the display body (should not happen after
        // ShabadCache's Manglacharan inclusion, but logged if it does).
        let effectiveLineId = Self.resolveEffectiveLineId(lineId, in: fetched)
        currentShabad = fetched
        currentLineId = effectiveLineId
        currentLineIdSetByFL = false  // server-driven, not FL
        currentShabadFLSigs = sigs
        currentShabadSafeStarters = starters
        currentShabadSafeBigrams = bigrams
        currentShabadFirstTwoWordSigs = firstTwo
        currentShabadSafeFirstTwoWordSigs = safeFirstTwo
        currentShabadRecentPeakScore = peakScore
        currentShabadRecentPeakTime = Date()
        currentDisplaySeq = seq
        pendingCandidate = nil
        // Brief #9.27: any lock transition clears the FL debounce +
        // line ping-pong state from the previous shabad. Old lineIds
        // and lastFLLineChangeAt would otherwise erroneously throttle
        // the FIRST FL match on the new shabad.
        flLineGate.reset()
        // Brief #9.6: defensive — challengers should already be
        // empty in DISCOVERING (we don't touch the dict there) but
        // make sure the fresh lock starts with a clean slate.
        challengers.removeAll(keepingCapacity: true)
        lockState = .locked
        // Brief #9.26: dismiss the cloud on ANY lock transition —
        // covers fast-lock, accumulator lock, cloud auto-lock, and
        // manual cloud lock uniformly. Also reset the discovery
        // partial counter so re-entering discovery from a stop or
        // toggle starts from zero.
        dismissCandidateCloud(reason: "lock via=\(via)")
        discoveryPartialCount = 0
        NSLog("[DIAG] StreamingRaagiModeEngine FL snapshot shabadId=\(shabadId) sigsCount=\(sigs.count)")
        // Brief #9.10-iOS: dump every pangti's FL signature so traces
        // show exactly what the matcher is working against — helps
        // diagnose any remaining FL misses (unexpected normalization,
        // weird unicode, segmentation differences vs ASR partial).
        for (lineId, fl) in sigs {
            NSLog("[DIAG] StreamingRaagiModeEngine FL pangti shabadId=\(shabadId) lineId=\(lineId) fl='\(fl.joined(separator: " "))'")
        }

        NSLog("[DIAG] StreamingRaagiModeEngine LOCK shabadId=\(shabadId) via=\(via) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine display update: first shabad shabadId=\(shabadId) lineId=\(effectiveLineId) triggeringLineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", peakScore))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(effectiveLineId) currentDisplaySeq=\(seq)")
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
        // Brief #9.26 5: also fetches first-two-word signatures.
        // Brief #9.28: also fetches the safe-unique first-two-word
        // map that Tier B2 consumes.
        let fetched: FullShabad
        let sigs: [String: [String]]
        let starters: [String: String]
        let bigrams: [String: String]
        let firstTwo: [String: String]
        let safeFirstTwo: [String: String]
        do {
            let result = try await cache.shabadWithFLSignatures(forId: shabadId)
            fetched = result.shabad
            sigs = result.signatures
            starters = result.safeStarters
            bigrams = result.safeBigrams
            firstTwo = result.firstTwoWordSigs
            safeFirstTwo = result.safeFirstTwoWordSigs
        } catch {
            NSLog("[DIAG] StreamingRaagiModeEngine swap fetch failed shabadId=\(shabadId): \(error.localizedDescription) — keeping sticky display")
            return
        }
        if seq < currentDisplaySeq {
            NSLog("[DIAG] StreamingRaagiModeEngine match seq=\(seq) currentDisplaySeq=\(currentDisplaySeq) result=stale (post-fetch-swap)")
            return
        }

        let prevId = currentShabad?.id ?? "nil"
        // Brief #9.24 Part 7: anchor to the challenger's triggering
        // lineId (same policy as `lockTo`). Manglacharan is now in
        // `fetched.lines` so a swap onto a shabad whose triggering
        // hit was Mool Mantar lands on Mool Mantar.
        let effectiveLineId = Self.resolveEffectiveLineId(lineId, in: fetched)
        currentShabad = fetched
        currentLineId = effectiveLineId
        currentLineIdSetByFL = false  // server-driven swap
        currentShabadFLSigs = sigs
        currentShabadSafeStarters = starters
        currentShabadSafeBigrams = bigrams
        currentShabadFirstTwoWordSigs = firstTwo
        currentShabadSafeFirstTwoWordSigs = safeFirstTwo
        currentShabadRecentPeakScore = score
        currentShabadRecentPeakTime = Date()
        currentDisplaySeq = seq
        pendingCandidate = nil
        // Brief #9.6: drop ALL challengers on swap. The winner has
        // just become the new currentShabad; any remaining
        // challenger slots are evidence accrued under the OLD
        // currentShabad context and shouldn't carry over.
        challengers.removeAll(keepingCapacity: true)
        // Brief #9.27: same reset as `lockTo`. Old-shabad line state
        // and lastFLLineChangeAt must not throttle the new shabad's
        // first FL match.
        flLineGate.reset()
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
        NSLog("[DIAG] StreamingRaagiModeEngine display update: shabad swap from=\(prevId) to=\(shabadId) lineId=\(effectiveLineId) triggeringLineId=\(lineId) seq=\(seq) tier=\(tier) score=\(String(format: "%.1f", score))")
        NSLog("[DIAG] StreamingRaagiModeEngine.currentShabad sticky shabadId=\(shabadId) lineId=\(effectiveLineId) currentDisplaySeq=\(seq)")
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
