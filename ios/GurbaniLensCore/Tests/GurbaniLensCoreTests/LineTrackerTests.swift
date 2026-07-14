import XCTest
@testable import GurbaniLensCore

/// Brief #9.29 test suite for the ``LineTracker`` structure-prior
/// pangti tracker. Ten scenarios replay the raagi movement patterns
/// (kirtan sequential + hook returns, paath strictly sequential,
/// dense-shabad ambiguous first-letters) that motivated the tracker.
///
/// The tests are pure — no engine, no ShabadCache, no wall clock. All
/// wall-time arguments feed the tracker's ingest as `TimeInterval`
/// offsets from an arbitrary anchor so the math is deterministic.
///
/// **Threshold arithmetic reminder** (with brief's constants):
///   change fires when `accumulator × prior ≥ 0.55`
///   serverMatch strength = score / 100
///   flSafeUnique strength = 0.6
///   priors: stay=1.0, next=1.0, kirtan hook=1.0, paath hook=0.3,
///           prev=0.5, kirtan other=0.15, paath other=0.1
///
/// Consequences worth remembering when reading the tests:
///   - Server 85 for the next line → 0.85 × 1.0 = 0.85 → fires on one hit.
///   - Server 85 for a random pangti (kirtan) → 0.128 → needs many
///     accumulated hits (~5 at score 80) to cross 0.55.
///   - Server 88 for a random pangti (paath) → 0.088 → needs even more
///     accumulated hits (~7) since paath's other-prior is tighter.
///   - flSafeUnique for next → 0.6 → fires; for random → 0.09 → stay.
///   - flAmbiguous distributes 0.25 only to stay/next/hook candidates.
final class LineTrackerTests: XCTestCase {

    // MARK: - Sequential progression

    func test_paathSequentialProgression() {
        // Paath is 95%+ strictly sequential. A server match for the
        // next line each with score 85 must fire on one hit, spaced
        // outside the 800 ms debounce.
        var tracker = LineTracker(
            mode: .paath, lineCount: 20, initialLineIndex: 0, now: 0
        )
        var visits: [Int] = [0]

        for i in 1...3 {
            let d = tracker.ingest(
                .serverMatch(lineIndex: i, score: 85),
                at: TimeInterval(i)  // 1 s spacing beats the 0.8 s debounce.
            )
            XCTAssertEqual(
                d.newLineIndex, i,
                "Sequential next-line at score 85 must fire immediately (line \(i))"
            )
            visits.append(d.newLineIndex!)
        }
        XCTAssertEqual(visits, [0, 1, 2, 3])
        XCTAssertEqual(tracker.currentLineIndex, 3)
    }

    // MARK: - Random-jump rejection

    func test_paathRejectsRandomJump() {
        // On line 2, a single server match for line 17 must NOT
        // teleport the highlight — 0.88 × 0.10 = 0.088, well below
        // the 0.55 fire threshold. A SUSTAINED stream of matches for
        // the same random line does eventually fire (raagi genuinely
        // skipped). With the paath other-prior of 0.10, seven matches
        // at score 88 within a rapid burst clear 0.55 after decay.
        var tracker = LineTracker(
            mode: .paath, lineCount: 30, initialLineIndex: 2, now: 0
        )
        let single = tracker.ingest(
            .serverMatch(lineIndex: 17, score: 88), at: 0
        )
        XCTAssertNil(
            single.newLineIndex,
            "One random-line match at 88 in paath must NOT fire (0.088 < 0.55)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 2)

        // Six more matches within 700 ms, spaced 100 ms apart, keep
        // the accumulator well below 0.55 for the first several then
        // finally cross. The exact firing hit is timing-sensitive
        // (decay slightly erodes older weight); assert only the end
        // state: after seven hits the line change has been committed.
        for k in 1...6 {
            _ = tracker.ingest(
                .serverMatch(lineIndex: 17, score: 88),
                at: TimeInterval(k) * 0.1
            )
        }
        XCTAssertEqual(
            tracker.currentLineIndex, 17,
            "Seven server matches at 88 within 700 ms must eventually fire — genuine skip"
        )
    }

    // MARK: - Hook return (kirtan)

    func test_kirtanHookReturn() {
        // Locked at line 0 (hook). Advance to line 5 via five
        // sequential-next commits. From line 5 with hook still at 0,
        // an FL safe-unique hit for line 0 must fire immediately —
        // hook prior in kirtan is 1.0, so 0.6 × 1.0 = 0.6 ≥ 0.55.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 12, initialLineIndex: 0, now: 0
        )
        for i in 1...5 {
            let d = tracker.ingest(
                .serverMatch(lineIndex: i, score: 90),
                at: TimeInterval(i)  // 1 s spacing per debounce.
            )
            XCTAssertEqual(d.newLineIndex, i)
        }
        XCTAssertEqual(tracker.currentLineIndex, 5)
        XCTAssertEqual(
            tracker.hookLineIndex, 0,
            "Hook must remain at line 0 through routine sequential progression"
        )

        // FL safe-unique for the hook line. At t = 7 (2 s past the
        // last commit) we're well past the 0.8 s debounce.
        let d = tracker.ingest(.flSafeUnique(lineIndex: 0), at: 7.0)
        XCTAssertEqual(
            d.newLineIndex, 0,
            "flSafeUnique for hook line in kirtan must fire (0.6 × 1.0 = 0.6)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 0)
    }

    // MARK: - Hook promotion

    func test_kirtanHookUpdate() {
        // The initial hook is line 0. Progress to line 2. Then a
        // steady stream of server matches on line 2 accumulates
        // confirmations. When confirmationCounts[2] exceeds hook count
        // by ≥ 2, the hook must promote to line 2.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 8, initialLineIndex: 0, now: 0
        )
        // Move 0 → 1 → 2.
        _ = tracker.ingest(.serverMatch(lineIndex: 1, score: 90), at: 1.0)
        _ = tracker.ingest(.serverMatch(lineIndex: 2, score: 90), at: 2.0)
        XCTAssertEqual(tracker.currentLineIndex, 2)
        XCTAssertEqual(tracker.hookLineIndex, 0)
        // Baseline: confirmationCounts[0] = 1 (from init), [1] = 1
        // (commit), [2] = 1 (commit). Need [2] ≥ [0] + 2 = 3 → two
        // more stay-confirms on line 2.
        _ = tracker.ingest(.serverMatch(lineIndex: 2, score: 90), at: 3.0)
        XCTAssertEqual(
            tracker.hookLineIndex, 0,
            "Two confirmations on line 2 not yet enough — margin requires 3"
        )
        _ = tracker.ingest(.serverMatch(lineIndex: 2, score: 90), at: 4.0)
        XCTAssertEqual(
            tracker.hookLineIndex, 2,
            "Third confirmation on line 2 (count 3 vs hook 1) promotes hook to 2"
        )
    }

    // MARK: - flAmbiguous never teleports

    func test_flAmbiguousCannotTeleport() {
        // Kirtan mode, on line 3, ambiguous FL for random pangtis
        // 15 and 20. Neither is stay/next/hook — favored set is
        // empty, so zero evidence is distributed and no accumulator
        // grows. Repeat it many times: the tracker stays.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 25, initialLineIndex: 3, now: 0
        )
        // Ensure hook != any of the ambiguous candidates.
        XCTAssertEqual(tracker.hookLineIndex, 3)

        for k in 0..<10 {
            let d = tracker.ingest(
                .flAmbiguous(candidates: [15, 20]),
                at: TimeInterval(k) * 0.2
            )
            XCTAssertNil(
                d.newLineIndex,
                "flAmbiguous with only non-favored candidates must never fire"
            )
        }
        XCTAssertEqual(tracker.currentLineIndex, 3)
        XCTAssertEqual(tracker.evidenceWeight(forLineIndex: 15), 0)
        XCTAssertEqual(tracker.evidenceWeight(forLineIndex: 20), 0)
    }

    // MARK: - flSafeUnique gating

    func test_flSafeUniqueNextLineFires() {
        // On line 3, flSafeUnique(4) — line 4 is next.
        // 0.6 × 1.0 = 0.6 ≥ 0.55 → fires immediately.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 10, initialLineIndex: 3, now: 0
        )
        let d = tracker.ingest(.flSafeUnique(lineIndex: 4), at: 0)
        XCTAssertEqual(
            d.newLineIndex, 4,
            "flSafeUnique for the next line must fire (0.6 × 1.0 = 0.6)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 4)
    }

    func test_flSafeUniqueRandomLineDoesNotFire() {
        // On line 3, flSafeUnique(20) — line 20 is random (not
        // stay/next/prev/hook). Prior = 0.15 (kirtan other).
        // 0.6 × 0.15 = 0.09 → stay. Even multiple hits at 4 s
        // spacing (evidence decays fully across each gap) never fire.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 25, initialLineIndex: 3, now: 0
        )
        for k in 0..<3 {
            let d = tracker.ingest(
                .flSafeUnique(lineIndex: 20),
                at: TimeInterval(k) * 5.0  // 5 s spacing → aggressive decay
            )
            XCTAssertNil(
                d.newLineIndex,
                "flSafeUnique for a random line must never fire alone (0.09 < 0.55)"
            )
        }
        XCTAssertEqual(tracker.currentLineIndex, 3)
    }

    // MARK: - Server evidence accumulates

    func test_serverEvidenceAccumulates() {
        // Kirtan mode, on line 3, server matches at score 80 for
        // random line 15. 0.80 × 0.15 = 0.12 per hit (raw × prior).
        // Two matches → 0.24 → stay. The accumulator needs enough
        // total weight × prior to cross 0.55; with rapid clustering
        // (little decay) five matches at 80 hit ~ 5 × 0.80 × 0.15 =
        // 0.60 → fires.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 20, initialLineIndex: 3, now: 0
        )
        // Two rapid matches: below fire.
        _ = tracker.ingest(.serverMatch(lineIndex: 15, score: 80), at: 0.0)
        let d2 = tracker.ingest(
            .serverMatch(lineIndex: 15, score: 80), at: 0.1
        )
        XCTAssertNil(
            d2.newLineIndex,
            "Two matches at score 80 for a random line must not fire (accum ≈ 0.24)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 3)

        // Three more matches within a further 300 ms — total five
        // rapid hits. The accumulator clears 0.55.
        for k in 2...4 {
            _ = tracker.ingest(
                .serverMatch(lineIndex: 15, score: 80),
                at: TimeInterval(k) * 0.1
            )
        }
        XCTAssertEqual(
            tracker.currentLineIndex, 15,
            "Five rapid matches at 80 for the same random line must eventually fire"
        )
    }

    // MARK: - Debounce

    func test_debounce800ms() {
        // Commit line 4 at t=1.0 (next-line fires immediately). A
        // subsequent flSafeUnique for line 5 at t=1.5 (500 ms later)
        // must be debounced — 500 < 800 ms. A retry at t=2.0
        // (1000 ms after the commit) succeeds.
        var tracker = LineTracker(
            mode: .kirtan, lineCount: 10, initialLineIndex: 3, now: 0
        )
        let d1 = tracker.ingest(.serverMatch(lineIndex: 4, score: 92), at: 1.0)
        XCTAssertEqual(d1.newLineIndex, 4)

        let d2 = tracker.ingest(.flSafeUnique(lineIndex: 5), at: 1.5)
        XCTAssertNil(
            d2.newLineIndex,
            "Second change 500 ms after the first must be debounced"
        )
        XCTAssertTrue(
            d2.reason.contains("debounced"),
            "Reason should mention debounce; got: \(d2.reason)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 4)

        let d3 = tracker.ingest(.flSafeUnique(lineIndex: 5), at: 2.0)
        XCTAssertEqual(
            d3.newLineIndex, 5,
            "Change 1000 ms after the last commit must succeed"
        )
    }

    // MARK: - Anand Sahib dense scenario

    func test_anandSahibDenseScenario() {
        // Paath mode, 10-line shabad. Lines 2, 5, 8 share dense first
        // letters. Server correctly advances 0→1→2→3 while FL keeps
        // firing ambiguous candidates [2, 5, 8] between real matches.
        // The tracker must follow 0→1→2→3 exactly and never visit
        // lines 5 or 8 — ambiguous FL only nudges prior-favored
        // candidates (stay/next/hook).
        var tracker = LineTracker(
            mode: .paath, lineCount: 10, initialLineIndex: 0, now: 0
        )
        var visits: [Int] = [0]
        var extras: [Int] = []

        // Helper to feed a server progress step, spaced 1 s to clear
        // debounce. Interleaves an ambiguous FL hit 500 ms before
        // each server match.
        func step(server target: Int, at anchor: TimeInterval) {
            let amb = tracker.ingest(
                .flAmbiguous(candidates: [2, 5, 8]), at: anchor - 0.5
            )
            if let n = amb.newLineIndex { extras.append(n) }
            let d = tracker.ingest(
                .serverMatch(lineIndex: target, score: 88), at: anchor
            )
            if let n = d.newLineIndex { visits.append(n) }
        }

        step(server: 1, at: 1.0)
        step(server: 2, at: 2.0)
        step(server: 3, at: 3.0)

        XCTAssertEqual(
            visits, [0, 1, 2, 3],
            "Tracker must follow sequential progression exactly through dense first-letters"
        )
        XCTAssertTrue(
            extras.isEmpty,
            "flAmbiguous must never contribute a commit; got extras=\(extras)"
        )
        XCTAssertEqual(tracker.currentLineIndex, 3)
        XCTAssertFalse(visits.contains(5), "Line 5 must never appear in visit history")
        XCTAssertFalse(visits.contains(8), "Line 8 must never appear in visit history")
        XCTAssertEqual(
            tracker.evidenceWeight(forLineIndex: 5), 0,
            "Line 5 must never have accumulated evidence"
        )
        XCTAssertEqual(
            tracker.evidenceWeight(forLineIndex: 8), 0,
            "Line 8 must never have accumulated evidence"
        )
    }
}
