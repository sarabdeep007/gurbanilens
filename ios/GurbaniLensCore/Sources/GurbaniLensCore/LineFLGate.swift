import Foundation

/// Brief #9.27: three-gate suppressor for the ``StreamingRaagiModeEngine``
/// first-letter (FL) fast-path within the LOCKED sung-mode state.
///
/// The FL fast-path in the engine walks a locked shabad's precomputed FL
/// signatures on every ASR partial to detect within-shabad pangti jumps
/// faster than the server's lineId can. Deep's post-#9.26 iPhone log
/// showed the FL bigram tier confirming *wrong* line jumps
/// (XLVS/H0Y2/RENR/H942/90CQ) across 32 consecutive `event=no_confident_match`
/// server heartbeats — the FL matcher had no signal that the server
/// itself had rejected each partial as low-confidence garbage, and no
/// throttle on how fast successive jumps could commit.
///
/// This gate composes three independent throttles applied to any FL-proposed
/// line change:
///
/// 1. **Server confidence gate** — when the server has emitted
///    `event=no_confident_match` or `event=alaap` for the current
///    partial's seq, the FL walk is suppressed entirely for that
///    partial. A short LRU of the last ``maxSeqsTracked`` seqs is
///    retained so out-of-order arrivals still find their verdict.
///
/// 2. **Debounce** — after any FL line-change commit, subsequent
///    FL-proposed changes to a *different* line within ``debounceSeconds``
///    are buffered as a `pendingLine`. A pending change is accepted the
///    moment the same lineId is proposed a second time; otherwise it
///    decays after ``pendingPartialsWindow`` further partials.
///
/// 3. **Line ping-pong guard** — same design as Brief #9.23e's shabad-
///    level `recordAndCheckPingPong`, but tighter tunables. Three swaps
///    between the same two lineIds within ``linePingPongWindowSeconds``
///    freeze the pair for ``linePingPongLockoutSeconds``. Swaps to a
///    third line proceed and reset state.
///
/// Only the engine's LOCKED sung-mode path invokes this gate — speech
/// mode and DISCOVERING skip it entirely so pre-#9.27 behavior stays
/// byte-identical there.
public struct LineFLGate: Equatable {

    // MARK: - Nested types

    /// Categorization of a server-side rejection for a specific seq.
    /// Mirrors the two `StreamingEvent` variants that indicate the
    /// server considered the partial too weak to emit a `match` for.
    public enum ServerRejection: String, Equatable {
        case noConfidentMatch = "no_confident_match"
        case alaap = "alaap"
    }

    /// Decision returned from ``decideLineChange(currentLine:proposedLine:seq:now:)``.
    /// The engine switches on the case to route the log line + decide
    /// whether to commit the FL-proposed change.
    public enum Decision: Equatable {
        /// Change is permitted. Caller commits `proposedLine`.
        case allow
        /// Server rejected this seq via `event=no_confident_match` or
        /// `event=alaap`. Caller must NOT commit.
        case suppressedByServerRejection(seq: Int, reason: String)
        /// Change fell inside the debounce window and was buffered as
        /// ``pendingLine``. Caller must NOT commit; a second same-line
        /// proposal within the window will be accepted on that call.
        case debounced(msSinceLastChange: Int, line: String)
        /// Ping-pong detected between `lineA` and `lineB` — same pair
        /// swapped `swapCount` times in ``linePingPongWindowSeconds``.
        /// Caller must NOT commit; lockout is armed.
        case pingPongDenied(lineA: String, lineB: String, swapCount: Int)
    }

    /// Buffered pending line change waiting for a confirmatory second
    /// FL proposal within the debounce window.
    public struct PendingLineChange: Equatable {
        public var lineId: String
        public var partialsRemaining: Int
        public init(lineId: String, partialsRemaining: Int) {
            self.lineId = lineId
            self.partialsRemaining = partialsRemaining
        }
    }

    /// Sliding-window tracker for swaps between the same pair of lines.
    /// Mirrors ``SungModeAccumulatorStore/PingPongState`` at the line
    /// level with different tunables.
    public struct LinePingPongState: Equatable {
        public var lineA: String
        public var lineB: String
        public var swapTimestamps: [Date]
        public init(lineA: String, lineB: String, swapTimestamps: [Date]) {
            self.lineA = lineA
            self.lineB = lineB
            self.swapTimestamps = swapTimestamps
        }
    }

    // MARK: - Tunables

    /// LRU cap on the number of recent server-rejection seqs retained.
    /// Deep's log showed 32 consecutive rejected partials — 30 keeps the
    /// window tight enough that old rejections don't linger past the
    /// current alaap event.
    public static let maxSeqsTracked: Int = 30
    /// Minimum wall-clock separation between successive FL line changes.
    /// 800 ms is well above the ~750 ms server partial cadence so a
    /// second FL proposal in the same partial batch is buffered rather
    /// than committed.
    public static let debounceSeconds: TimeInterval = 0.8
    /// How many further FL proposals a ``PendingLineChange`` waits for
    /// before being dropped. A single confirmatory second proposal in
    /// this window commits the buffered change.
    public static let pendingPartialsWindow: Int = 2
    /// Sliding-window horizon over which same-pair swaps are counted.
    /// Deep's #9.27 log had 5 rapid HLD-tier line swaps within ~10 s —
    /// 20 s captures that pattern with room to spare.
    public static let linePingPongWindowSeconds: TimeInterval = 20.0
    /// Number of same-pair swaps within ``linePingPongWindowSeconds``
    /// before the pair is frozen. 3 lets a legitimate raagi "went
    /// back one line then forward" flow through.
    public static let linePingPongMaxSwaps: Int = 3
    /// How long (in seconds) the frozen pair stays denied after the
    /// swap count crosses ``linePingPongMaxSwaps``.
    public static let linePingPongLockoutSeconds: TimeInterval = 30.0

    // MARK: - State

    /// Server verdicts keyed by seq. Only ``ServerRejection`` cases are
    /// retained — successful matches are irrelevant to this gate.
    public private(set) var serverRejectionsBySeq: [Int: ServerRejection] = [:]
    /// FIFO ring backing the LRU eviction of stale seqs.
    public private(set) var recordedSeqs: [Int] = []

    /// Wall-clock time of the most recent COMMITTED FL line change.
    /// Nil before any change lands. Drives the debounce window.
    public private(set) var lastFLLineChangeAt: Date? = nil
    /// Buffered line change awaiting a confirmatory second proposal.
    public private(set) var pendingLine: PendingLineChange? = nil

    /// Sliding-window tracker for line-level ping-pong. Nil when no
    /// pair is being watched; populated on the first line change.
    public private(set) var linePingPongState: LinePingPongState? = nil
    /// Absolute wall-clock time at which the current line ping-pong
    /// lockout expires. Nil when no lockout is active.
    public private(set) var linePingPongLockoutUntil: Date? = nil

    public init() {}

    // MARK: - Server-rejection recording

    /// Record a server verdict indicating the partial for `seq` was
    /// rejected as low-confidence. Called from the engine's `.alaap`
    /// and `.noConfidentMatch` event handlers.
    public mutating func recordServerRejection(seq: Int, reason: ServerRejection) {
        if serverRejectionsBySeq[seq] == nil {
            recordedSeqs.append(seq)
        }
        serverRejectionsBySeq[seq] = reason
        while recordedSeqs.count > Self.maxSeqsTracked {
            let evicted = recordedSeqs.removeFirst()
            serverRejectionsBySeq.removeValue(forKey: evicted)
        }
    }

    /// Fast lookup used by the engine to short-circuit the entire FL
    /// walk at the top of `handlePartialForFLMatch` and emit a single
    /// diagnostic line rather than running the tier cascade + gating
    /// each commit site independently.
    public func isServerRejected(seq: Int) -> Bool {
        serverRejectionsBySeq[seq] != nil
    }

    public func serverRejectionReason(seq: Int) -> ServerRejection? {
        serverRejectionsBySeq[seq]
    }

    // MARK: - Decision entry

    /// Evaluate whether an FL-proposed line change should be applied.
    /// The three gates are checked in order: server rejection → same-
    /// line (trivial allow) → pending confirmation → debounce → line
    /// ping-pong.
    public mutating func decideLineChange(
        currentLine: String,
        proposedLine: String,
        seq: Int,
        now: Date
    ) -> Decision {
        if let reason = serverRejectionsBySeq[seq] {
            return .suppressedByServerRejection(seq: seq, reason: reason.rawValue)
        }

        if currentLine == proposedLine {
            return .allow
        }

        if var pending = pendingLine {
            if pending.lineId == proposedLine {
                // Buffered change confirmed a second time. Clear the
                // pending marker regardless of the outcome — the
                // caller has expressed intent. Ping-pong is still the
                // stronger gate: even a confirmed change can be
                // denied if it's part of an oscillating pair.
                pendingLine = nil
                if recordAndCheckLinePingPong(from: currentLine, to: proposedLine, now: now) {
                    let state = linePingPongState
                    return .pingPongDenied(
                        lineA: state?.lineA ?? currentLine,
                        lineB: state?.lineB ?? proposedLine,
                        swapCount: state?.swapTimestamps.count ?? 0
                    )
                }
                lastFLLineChangeAt = now
                return .allow
            }
            pending.partialsRemaining -= 1
            if pending.partialsRemaining <= 0 {
                pendingLine = nil
            } else {
                pendingLine = pending
            }
        }

        if let last = lastFLLineChangeAt, now.timeIntervalSince(last) < Self.debounceSeconds {
            pendingLine = PendingLineChange(
                lineId: proposedLine,
                partialsRemaining: Self.pendingPartialsWindow
            )
            let ms = Int(now.timeIntervalSince(last) * 1000)
            return .debounced(msSinceLastChange: ms, line: proposedLine)
        }

        if recordAndCheckLinePingPong(from: currentLine, to: proposedLine, now: now) {
            let state = linePingPongState
            return .pingPongDenied(
                lineA: state?.lineA ?? currentLine,
                lineB: state?.lineB ?? proposedLine,
                swapCount: state?.swapTimestamps.count ?? 0
            )
        }

        lastFLLineChangeAt = now
        return .allow
    }

    /// Reset every state field. Called by the engine on `start`, `stop`,
    /// and `didToggleSungMode`.
    public mutating func reset() {
        serverRejectionsBySeq.removeAll()
        recordedSeqs.removeAll()
        lastFLLineChangeAt = nil
        pendingLine = nil
        linePingPongState = nil
        linePingPongLockoutUntil = nil
    }

    // MARK: - Ping-pong internals

    /// Record a pending line change from `currentLine` to `proposedLine`
    /// and return `true` if it should be BLOCKED as ping-pong. Same
    /// six-step decision tree as ``SungModeAccumulatorStore/recordAndCheckPingPong``
    /// at the shabad level, retuned for line-level tunables.
    ///
    /// `internal` so the unit tests can drive the state machine directly
    /// without staging debounce windows.
    @discardableResult
    internal mutating func recordAndCheckLinePingPong(
        from currentLine: String,
        to proposedLine: String,
        now: Date
    ) -> Bool {
        if let until = linePingPongLockoutUntil, now >= until {
            NSLog("[DIAG] LineFLGate line ping-pong lockout expired at now=\(now.timeIntervalSince1970)")
            linePingPongState = nil
            linePingPongLockoutUntil = nil
        }

        let newPair = Set([currentLine, proposedLine])

        guard var state = linePingPongState else {
            linePingPongState = LinePingPongState(
                lineA: currentLine, lineB: proposedLine, swapTimestamps: [now]
            )
            return false
        }

        let existingPair = Set([state.lineA, state.lineB])
        if existingPair != newPair {
            linePingPongLockoutUntil = nil
            linePingPongState = LinePingPongState(
                lineA: currentLine, lineB: proposedLine, swapTimestamps: [now]
            )
            return false
        }

        if linePingPongLockoutUntil != nil {
            NSLog("[DIAG] SungModeAccumulator line ping-pong lockout active — denying swap from=\(currentLine) to=\(proposedLine) lineA=\(state.lineA) lineB=\(state.lineB)")
            return true
        }

        state.swapTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-Self.linePingPongWindowSeconds)
        state.swapTimestamps.removeAll { $0 < cutoff }
        if state.swapTimestamps.count >= Self.linePingPongMaxSwaps {
            linePingPongState = state
            linePingPongLockoutUntil = now.addingTimeInterval(Self.linePingPongLockoutSeconds)
            NSLog("[DIAG] SungModeAccumulator line ping-pong DETECTED lineA=\(state.lineA) lineB=\(state.lineB) swapCount=\(state.swapTimestamps.count) — freezing on \(currentLine) for \(Int(Self.linePingPongLockoutSeconds))s")
            return true
        }
        linePingPongState = state
        return false
    }
}
