import XCTest
@testable import GurbaniLensCore

/// Brief #9.27: three-gate suppressor for the FL fast-path. Tests
/// each gate (server-confidence, debounce, line ping-pong) in
/// isolation using the pure-value ``LineFLGate`` type. The engine
/// integration is exercised in-app; here we lock down the gate's
/// state-machine semantics.
final class LineFLGateTests: XCTestCase {

    /// Fixed anchor so `Date()` differences are exactly what the test
    /// intends and there's no wall-clock drift.
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - Debounce

    func test_lineFLDebounce_dropsRapidSwap() {
        // Baseline change lands at t=0, sets `lastFLLineChangeAt`.
        // A second change 500 ms later — still inside the 800 ms
        // window — must be buffered as `.debounced`, and the gate
        // must record the buffered `pendingLine`.
        var gate = LineFLGate()
        let d1 = gate.decideLineChange(
            currentLine: "L0", proposedLine: "A", seq: 1, now: at(0)
        )
        XCTAssertEqual(d1, .allow)
        XCTAssertEqual(gate.lastFLLineChangeAt, at(0))

        let d2 = gate.decideLineChange(
            currentLine: "A", proposedLine: "B", seq: 2, now: at(0.5)
        )
        guard case .debounced(let ms, let line) = d2 else {
            XCTFail("Expected .debounced for a 500 ms change, got \(d2)"); return
        }
        XCTAssertEqual(line, "B")
        XCTAssertEqual(ms, 500)
        // Buffered but not committed — lastFLLineChangeAt unchanged.
        XCTAssertEqual(gate.lastFLLineChangeAt, at(0))
        XCTAssertEqual(gate.pendingLine?.lineId, "B")
        XCTAssertEqual(gate.pendingLine?.partialsRemaining, LineFLGate.pendingPartialsWindow)
    }

    func test_lineFLDebounce_acceptsSlowChange() {
        // 900 ms > 800 ms debounce → the second change is committed
        // outright, no pending buffer set, lastFLLineChangeAt updated.
        var gate = LineFLGate()
        _ = gate.decideLineChange(
            currentLine: "L0", proposedLine: "A", seq: 1, now: at(0)
        )
        let d2 = gate.decideLineChange(
            currentLine: "A", proposedLine: "B", seq: 2, now: at(0.9)
        )
        XCTAssertEqual(d2, .allow)
        XCTAssertNil(gate.pendingLine)
        XCTAssertEqual(gate.lastFLLineChangeAt, at(0.9))
    }

    // MARK: - Line ping-pong

    func test_linePingPongDetection_blocksThirdSwap() {
        // Same design as the Brief #9.23e shabad-level test: two
        // A↔B swaps within the 20 s window are allowed, the third
        // is denied and arms a 30 s lockout on the pair.
        var gate = LineFLGate()

        let b1 = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(0))
        XCTAssertFalse(b1, "First swap between a fresh line pair must be allowed")
        XCTAssertEqual(
            gate.linePingPongState.map { Set([$0.lineA, $0.lineB]) },
            Set(["L1", "L2"])
        )
        XCTAssertEqual(gate.linePingPongState?.swapTimestamps.count, 1)
        XCTAssertNil(gate.linePingPongLockoutUntil)

        let b2 = gate.recordAndCheckLinePingPong(from: "L2", to: "L1", now: at(5))
        XCTAssertFalse(b2, "Second swap between the same pair must be allowed")
        XCTAssertEqual(gate.linePingPongState?.swapTimestamps.count, 2)
        XCTAssertNil(gate.linePingPongLockoutUntil)

        let b3 = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(10))
        XCTAssertTrue(b3, "Third swap between the same pair within 20 s must be BLOCKED")
        XCTAssertEqual(gate.linePingPongState?.swapTimestamps.count, 3)
        XCTAssertNotNil(gate.linePingPongLockoutUntil, "Lockout must be armed on ping-pong detection")
        let expectedUntil = at(10).addingTimeInterval(LineFLGate.linePingPongLockoutSeconds)
        XCTAssertEqual(
            gate.linePingPongLockoutUntil?.timeIntervalSince1970 ?? 0,
            expectedUntil.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func test_linePingPongDetection_allowsSwapToThirdLine() {
        // Establish an active lockout on L1↔L2, then request a swap
        // to a third line L3 while the lockout is live. Pair-specific
        // freeze must let the L3 swap through and reset state.
        var gate = LineFLGate()
        _ = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(0))
        _ = gate.recordAndCheckLinePingPong(from: "L2", to: "L1", now: at(5))
        _ = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(10))
        XCTAssertNotNil(gate.linePingPongLockoutUntil, "Precondition: lockout is active")

        let b = gate.recordAndCheckLinePingPong(from: "L2", to: "L3", now: at(12))
        XCTAssertFalse(b, "Swap involving a third line must proceed during pair lockout")
        XCTAssertEqual(
            gate.linePingPongState.map { Set([$0.lineA, $0.lineB]) },
            Set(["L2", "L3"]),
            "State must reset to track the new pair"
        )
        XCTAssertEqual(gate.linePingPongState?.swapTimestamps.count, 1)
        XCTAssertNil(gate.linePingPongLockoutUntil, "Pair reset must not carry stale lockout")
    }

    func test_linePingPongDetection_clearsAfterLockoutWindow() {
        // Lockout is armed at t=10 (30 s expiry → t=40). One second
        // past expiry the SAME pair swap is allowed again; expired
        // state clears and a fresh single-timestamp state seeds.
        var gate = LineFLGate()
        _ = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(0))
        _ = gate.recordAndCheckLinePingPong(from: "L2", to: "L1", now: at(5))
        _ = gate.recordAndCheckLinePingPong(from: "L1", to: "L2", now: at(10))
        XCTAssertNotNil(gate.linePingPongLockoutUntil, "Precondition: lockout is active")

        let past = 10.0 + LineFLGate.linePingPongLockoutSeconds + 1.0
        let b = gate.recordAndCheckLinePingPong(from: "L2", to: "L1", now: at(past))
        XCTAssertFalse(b, "Same-pair swap must be allowed after the lockout expires")
        XCTAssertNil(gate.linePingPongLockoutUntil, "Expired lockout must be cleared")
        XCTAssertEqual(
            gate.linePingPongState.map { Set([$0.lineA, $0.lineB]) },
            Set(["L1", "L2"]),
            "Fresh state must seed on the same pair after lockout expiry"
        )
        XCTAssertEqual(gate.linePingPongState?.swapTimestamps.count, 1)
    }

    // MARK: - Server-confidence gate

    func test_lineFLServerConfidenceGate_suppressedOnNoConfidentMatch() {
        // Server rejected seq=42 as no_confident_match. A subsequent
        // FL-proposed change with the same seq must yield
        // .suppressedByServerRejection AND leave all downstream state
        // (debounce, ping-pong) untouched.
        var gate = LineFLGate()
        gate.recordServerRejection(seq: 42, reason: .noConfidentMatch)
        XCTAssertTrue(gate.isServerRejected(seq: 42))
        XCTAssertEqual(gate.serverRejectionReason(seq: 42), .noConfidentMatch)

        let d = gate.decideLineChange(
            currentLine: "A", proposedLine: "B", seq: 42, now: at(0)
        )
        guard case .suppressedByServerRejection(let s, let reason) = d else {
            XCTFail("Expected .suppressedByServerRejection, got \(d)"); return
        }
        XCTAssertEqual(s, 42)
        XCTAssertEqual(reason, "no_confident_match")
        // Downstream state must not have been touched.
        XCTAssertNil(gate.lastFLLineChangeAt)
        XCTAssertNil(gate.pendingLine)
        XCTAssertNil(gate.linePingPongState)

        // A different seq with the same partial content still passes.
        XCTAssertFalse(gate.isServerRejected(seq: 43))
        let d2 = gate.decideLineChange(
            currentLine: "A", proposedLine: "B", seq: 43, now: at(0.001)
        )
        XCTAssertEqual(d2, .allow)
    }

    func test_lineFLServerConfidenceGate_suppressedOnAlaap() {
        // Same story for event=alaap. The gate reports the two
        // rejection kinds as distinct so the DIAG log can attribute
        // the suppression cause.
        var gate = LineFLGate()
        gate.recordServerRejection(seq: 77, reason: .alaap)
        XCTAssertTrue(gate.isServerRejected(seq: 77))
        XCTAssertEqual(gate.serverRejectionReason(seq: 77), .alaap)

        let d = gate.decideLineChange(
            currentLine: "A", proposedLine: "B", seq: 77, now: at(0)
        )
        guard case .suppressedByServerRejection(let s, let reason) = d else {
            XCTFail("Expected .suppressedByServerRejection, got \(d)"); return
        }
        XCTAssertEqual(s, 77)
        XCTAssertEqual(reason, "alaap")
        XCTAssertNil(gate.lastFLLineChangeAt)
        XCTAssertNil(gate.pendingLine)
        XCTAssertNil(gate.linePingPongState)
    }
}
