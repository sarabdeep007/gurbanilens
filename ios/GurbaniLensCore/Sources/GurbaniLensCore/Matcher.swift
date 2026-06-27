import Foundation

/// Fuzzy Pangti matcher. Swift port of `core/gurbanilens/matcher.py:Matcher`.
/// Validated against `core/tests/portparity/test_vectors.json`.
///
/// Sendable: `Matcher` is immutable after init (`let` lines / normalizedTexts /
/// tokens / firstLetters), so it's safe to hand to a `Task.detached` from
/// MainActor without touching mutable state. We declare `@unchecked Sendable`
/// to make that explicit at the type level — the app target moves match() off
/// MainActor to keep the UI thread snappy on long queries.
///
/// ### First-letters pre-filter (2026-06-20)
///
/// The Python canonical (`core/gurbanilens/matcher.py`) runs `process.extract`
/// over all ~60K SGGS lines via rapidfuzz's hardware-tuned C++ — on a Mac
/// this is ~0.7 s. The naive Swift port runs the equivalent loop in pure
/// Swift; on iPhone ARM with String/UnicodeScalar overhead per call, the same
/// loop is ~100-300× slower (Deep's on-device test: 213 s per query).
///
/// We add a cheap Stage 0 pre-filter that does NOT change which candidates
/// can reach the top of Stage 1 / Stage 2 — only what the inputs to Stage 1
/// are. The idea: for each Pangti, compute the abbreviation
/// "first letter of each transliteration token" once at index time
/// (e.g. "meenaa jalaheen meenaa jalaheen he" → "mjmjh"). At query time
/// the same abbreviation is extracted from the normalised query
/// (e.g. "iaskskp" for "ika amkaar saath naam karataa purakh"). We rank
/// corpus lines by `partial_ratio(qFL, lineFL)` — a partial_ratio on
/// ~5–15 char strings is roughly 1000× cheaper than on full 35–50 char
/// strings — and keep the top ``prefilterPoolCap`` for Stage 1.
///
/// Port-parity contract: when ``prefilterPoolCap`` is generous enough that
/// every correct match is preserved (1500 is comfortably above the
/// honest-recall threshold for SGGS-sized corpora), the final top-N is
/// identical to the no-pre-filter version. The 11/11 test_vectors.json
/// battery is the regression net.
public final class Matcher: @unchecked Sendable {
    // Thresholds — must match test_vectors.json#/thresholds
    public static let tokenMatchThreshold: Double = 55.0
    public static let longTokenMin: Int = 3
    public static let minLongTokensForFullConfidence: Int = 4
    public static let candidatePool: Int = 50

    // Pre-filter knobs — chosen to preserve port-parity while bringing
    // iPhone-ARM match time from ~213 s to ~2-5 s on a 60K-line corpus.
    /// Maximum candidates handed to Stage 1 after the first-letters
    /// filter.
    ///
    /// History:
    ///   - Phase 1: 1500 (Phase 1 port-parity validation).
    ///   - Brief #8.5 (2026-06-27): tried 600 to cut Tier 3 latency
    ///     from 5-13 s to ~2-5 s.
    ///   - Brief #8.6 (2026-06-27, this commit): **restored to 1500.**
    ///     Deep's #8.5 test compared "ਥਿਰੁ ਘਰਿ ਬੈਸਹੁ ਹਰਿ ਜਨ ਪਿਆਰੇ"
    ///     across the two values:
    ///       cap=1500 → tier 3 topScore=96.2
    ///       cap=600  → tier 3 topScore=59.1
    ///     Saved 2 s of latency, lost 37 points of confidence — bad
    ///     trade. The correct answer for noisy ASR queries is
    ///     genuinely outside the top 600 by first-letters
    ///     ranking, even though it's a strong full-text match.
    public static let prefilterPoolCap: Int = 1500
    /// Queries with fewer than this many chars of first-letters skip the
    /// pre-filter entirely (too short to discriminate meaningfully).
    public static let prefilterMinQueryFL: Int = 3

    public let lines: [Line]
    /// Normalised English transliteration for each indexed line.
    let normalizedTexts: [String]
    /// Pre-split tokens for each indexed line (avoids repeated split work).
    let tokens: [[String]]
    /// First letter of each token (concatenated) for each indexed line.
    /// Used by the Stage 0 first-letters pre-filter.
    let firstLetters: [String]
    /// `firstLetters` after ``PhoneticEquivalence`` canonicalisation. Used
    /// by ``matchByFirstLetters(_:topN:)`` to make v2 live-matching robust
    /// to Whisper's voiced/unvoiced confusion (b↔p, g↔k, d↔t, j↔c).
    let phoneticFirstLetters: [String]
    /// Map from shabadId to the indices into ``lines`` that belong to
    /// that shabad. Built once at init. Powers
    /// ``match(_:restrictedToShabadIds:topN:)`` for O(1) shabad-scoped
    /// subset access — used by Raagi Mode's three-tier match cascade
    /// (Brief #8.3) to constrain matching to currentShabad / cached
    /// shabads before falling back to the full corpus.
    public let shabadIndex: [String: [Int]]

    public init(corpus: Corpus) throws {
        var ls: [Line] = []
        var nt: [String] = []
        var ts: [[String]] = []
        var fl: [String] = []
        var pfl: [String] = []
        var skippedSirlekh = 0
        var skippedNoTranslit = 0
        for line in try corpus.allLines() {
            // Skip Sirlekh (section headers like "Pauri", "Salok",
            // "Astpadi", "Ghar 2"). Their transliterations are 1–3
            // letters so partial_ratio trivially returns 100 against
            // any longer query — Deep's "ਹਮ ਰੁਲਤੇ ਫਿਰਤੇ" test (qFL
            // ~7 chars) returned 4× "Pauri" + 1× "Bhagat" with all
            // scores 100.0, zero actual pangti content in top-5.
            // Voice search is always for content the user is
            // reciting; section names are never a useful hit.
            // Filtering at index time is the cleanest fix — keeps
            // the scoring algorithm intact (port-parity preserved).
            if Self.isSirlekh(line) {
                skippedSirlekh += 1
                continue
            }
            guard let translit = line.transliterationEn else {
                skippedNoTranslit += 1
                continue
            }
            let normalized = normalize(translit)
            if normalized.isEmpty { continue }
            let toks = normalized.split(separator: " ").map { String($0) }
            let flValue = Self.firstLettersOf(tokens: toks)
            ls.append(line)
            nt.append(normalized)
            ts.append(toks)
            fl.append(flValue)
            pfl.append(PhoneticEquivalence.canonicalize(flValue))
        }
        self.lines = ls
        self.normalizedTexts = nt
        self.tokens = ts
        self.firstLetters = fl
        self.phoneticFirstLetters = pfl
        self.shabadIndex = Self.buildShabadIndex(lines: ls)
        NSLog("[DIAG] Matcher.init indexed=\(ls.count) shabads=\(shabadIndex.count) skippedSirlekh=\(skippedSirlekh) skippedNoTranslit=\(skippedNoTranslit)")
    }

    /// Convenience init for tests / future use that bypasses Corpus.
    /// Applies the same Sirlekh filter as ``init(corpus:)`` so test
    /// behaviour matches production.
    public init(prebuilt: [(line: Line, normalised: String, tokens: [String])]) {
        let filtered = prebuilt.filter { !Self.isSirlekh($0.line) }
        self.lines = filtered.map(\.line)
        self.normalizedTexts = filtered.map(\.normalised)
        self.tokens = filtered.map(\.tokens)
        let fl = filtered.map { Self.firstLettersOf(tokens: $0.tokens) }
        self.firstLetters = fl
        self.phoneticFirstLetters = fl.map { PhoneticEquivalence.canonicalize($0) }
        self.shabadIndex = Self.buildShabadIndex(lines: self.lines)
    }

    private static func buildShabadIndex(lines: [Line]) -> [String: [Int]] {
        var idx: [String: [Int]] = [:]
        idx.reserveCapacity(8_000)
        for (i, line) in lines.enumerated() {
            idx[line.shabadId, default: []].append(i)
        }
        return idx
    }

    /// Case-insensitive Sirlekh check — corpus may emit "Sirlekh",
    /// "sirlekh", or the Anmol Lipi original "isrlyK"; only the
    /// English label is normalised by `Corpus.allLines`, so a
    /// lowercase compare on `lineType` covers it.
    static func isSirlekh(_ line: Line) -> Bool {
        return line.lineType?.lowercased() == "sirlekh"
    }

    public var count: Int { lines.count }

    /// First letter of each token concatenated, e.g.
    /// ["meenaa","jalaheen","meenaa","jalaheen","he"] → "mjmjh".
    static func firstLettersOf(tokens: [String]) -> String {
        var fl = ""
        fl.reserveCapacity(tokens.count)
        for tok in tokens {
            if let first = tok.first { fl.append(first) }
        }
        return fl
    }

    /// **v2 live-matching fast path.** Scores corpus lines purely by
    /// `partial_ratio(canonicalisedQueryFL, canonicalisedLineFL)` over the
    /// pre-computed phonetic first-letters index. No Stage 1 full
    /// `partial_ratio` over normalised text, no Stage 2 token coverage.
    ///
    /// Why: v2's search-as-you-speak UX needs sub-100 ms matcher latency so
    /// the live result list feels responsive on every Whisper partial. The
    /// full ``match(_:topN:)`` takes 2–5 s on iPhone over a 60K-line corpus
    /// — too slow for live; appropriate only at commit time.
    ///
    /// Phonetic equivalence: Whisper-small frequently confuses voiced /
    /// unvoiced plosive pairs (b↔p, g↔k, d↔t) and palatal pairs (j↔c) on
    /// Punjabi audio. ``PhoneticEquivalence/canonicalize(_:)`` collapses
    /// each pair to a single canonical char before scoring so that
    /// "babbamn" and "pappamn" match identically.
    ///
    /// Returns up to `topN` matches with:
    ///   - `score` = `partialRatio` = phonetic first-letters ratio (0–100)
    ///   - `coverage = 1.0` — first-letters mode does not compute coverage;
    ///                       the field is filled in so callers can use the
    ///                       same `Match` struct uniformly. v2 callers
    ///                       (`VoiceSearchSession.commit`) re-rank by the
    ///                       full ``match(_:topN:)`` before showing the
    ///                       final Results screen.
    /// `confidenceCutoff` (default 0.80, added 2026-06-23): post-filter
    /// drops results whose `effective` score is below `cutoff * topScore`.
    /// Pass 0 to disable the filter (tests / call sites that want the
    /// raw ranked top-N regardless of confidence gap).
    public func matchByFirstLetters(
        _ query: String,
        topN: Int = 5,
        confidenceCutoff: Double = 0.80
    ) -> [Match] {
        let totalStart = Date()
        let normalised = normalize(query)
        if normalised.isEmpty { return [] }
        let qTokens = normalised.split(separator: " ").map { String($0) }
        let qFL = Self.firstLettersOf(tokens: qTokens)
        if qFL.isEmpty { return [] }
        let qFLp = PhoneticEquivalence.canonicalize(qFL)
        let qLen = qFLp.count

        // Length-aware scoring (added 2026-06-23). partial_ratio alone
        // returns 100 when a short line FL is substring-contained in a
        // longer query FL — e.g. a 2-char content line trivially wins
        // against a 7-char user query like "hrfkbnp", drowning out the
        // honest 7-char target line. Soften by multiplying through
        // sqrt(lengthFactor) so short lines still score but lose to
        // length-matched candidates. Sqrt instead of linear because we
        // want the penalty to be gentle (a 5-vs-7 character pair shouldn't
        // be punished much) while a 2-vs-7 pair should drop noticeably.
        var scored: [(effective: Double, partialRatio: Double, lengthFactor: Double, index: Int)] = []
        scored.reserveCapacity(phoneticFirstLetters.count)
        for (i, lineFLp) in phoneticFirstLetters.enumerated() {
            if lineFLp.isEmpty { continue }
            let pr = StringMetrics.partialRatio(qFLp, lineFLp)
            let lLen = lineFLp.count
            let lf = Double(min(qLen, lLen)) / Double(max(qLen, lLen))
            let effective = pr * sqrt(lf)
            scored.append((effective, pr, lf, i))
        }
        scored.sort { $0.effective > $1.effective }
        let top = Array(scored.prefix(topN))
        let totalMs = Int(Date().timeIntervalSince(totalStart) * 1000)

        let topEff = top.first.map { String(format: "%.1f", $0.effective) } ?? "n/a"
        let topPR = top.first.map { String(format: "%.1f", $0.partialRatio) } ?? "n/a"
        let topLF = top.first.map { String(format: "%.2f", $0.lengthFactor) } ?? "n/a"
        let topLineFL = top.first.map { phoneticFirstLetters[$0.index] } ?? ""
        NSLog("[DIAG] Matcher.matchByFirstLetters totalLines=\(phoneticFirstLetters.count) qFL=\"\(qFL)\" qFLp=\"\(qFLp)\" topEffective=\(topEff) topPR=\(topPR) topLF=\(topLF) topLineFL=\"\(topLineFL)\" totalMs=\(totalMs)")

        // Top-10 diagnostic log (added 2026-06-23). When a query
        // mis-ranks (e.g. Deep's "ਹਮ ਰੁਲਤੇ ਫਿਰਤੇ" failing to surface
        // Ang 167), the next debug step is "where in the ranked list
        // does the actual line sit?" Log the breakdown of the top 10
        // candidates with FL, partial_ratio, length-factor, effective
        // score, and ang so we can tell at a glance whether the target
        // is just below the topN cutoff or buried in the long tail.
        let top10 = Array(scored.prefix(10))
        let log10 = top10.enumerated().map { (idx, r) -> String in
            let line = lines[r.index]
            let flDisplay = phoneticFirstLetters[r.index]
            return "[\(idx + 1)] FLp='\(flDisplay)' pr=\(String(format: "%.1f", r.partialRatio)) lf=\(String(format: "%.2f", r.lengthFactor)) eff=\(String(format: "%.1f", r.effective)) ang=\(line.ang)"
        }.joined(separator: " | ")
        NSLog("[DIAG] Matcher.matchByFirstLetters TOP10: \(log10)")

        let allMatches = top.map { entry in
            Match(
                line: lines[entry.index],
                score: entry.effective,
                partialRatio: entry.partialRatio,
                coverage: 1.0
            )
        }

        // Confidence-based filtering (added 2026-06-23). When the top
        // match scores high, weak follow-ups are noise — they crowd
        // the UI without helping the user. Keep only results within
        // `confidenceCutoff` × top score. If the top is low (no clear
        // winner), most results pass the cutoff naturally so the user
        // still gets multiple options. Empty / 1-result cases fall
        // through unchanged. Pass 0 to opt out entirely.
        guard confidenceCutoff > 0, let topMatch = allMatches.first else {
            return allMatches
        }
        let cutoff = topMatch.score * confidenceCutoff
        let filtered = allMatches.filter { $0.score >= cutoff }
        NSLog("[DIAG] Matcher.matchByFirstLetters confidence filter — cutoffRatio=\(String(format: "%.2f", confidenceCutoff)) cutoff=\(String(format: "%.1f", cutoff)) kept=\(filtered.count)/\(allMatches.count)")
        return filtered
    }

    /// **Scoped match** (Brief #8.3, scoring fix in #8.4, 2026-06-27).
    /// Run Stage 1 (`partial_ratio` over normalised text, **length-
    /// softened**) + Stage 2 (`token_coverage` rescoring) over the
    /// subset of ``lines`` whose `shabadId` is in `shabadIds`. The
    /// Stage 0 first-letters prefilter is skipped — it exists to
    /// slice 60K → 1.5K, meaningless on 20–300-line scopes.
    ///
    /// **Stage 1 length softening** (Brief #8.4). Brief #8.3 ran a
    /// raw `partial_ratio` here, identical to the full ``match``'s
    /// Stage 1. That works in the full-corpus path because the Stage
    /// 0 prefilter implicitly biases the 1500 candidates entering
    /// Stage 1 toward length-matched lines (via its own
    /// `pr * sqrt(lengthFactor)` softening). With ~6 BSJ candidates
    /// in Tier 1, the prefilter is absent and a single short Rahao
    /// (~4 chars) can trivially `partial_ratio=100` against a 60-
    /// char query — winning Stage 1 over the actual length-matched
    /// pangti. Adding the prefilter's softening directly into
    /// matchScoped's Stage 1 restores parity-with-prefilter semantics
    /// while preserving the Stage 2 `× coverage` rescoring shape.
    ///
    /// Returns an empty array if `shabadIds` is empty or no
    /// matching lines exist. Confidence cutoff is applied by the
    /// caller (Raagi uses the same 70 threshold as ``match``).
    public func match(
        _ query: String,
        restrictedToShabadIds shabadIds: Set<String>,
        topN: Int = 5
    ) -> [Match] {
        let totalStart = Date()
        if shabadIds.isEmpty { return [] }
        let normalised = normalize(query)
        if normalised.isEmpty { return [] }
        let qLong = longTokens(normalised)
        let qLen = normalised.count

        // Gather candidate indices from the precomputed shabadIndex.
        var candidateIndices: [Int] = []
        candidateIndices.reserveCapacity(64)
        for sid in shabadIds {
            if let indices = shabadIndex[sid] {
                candidateIndices.append(contentsOf: indices)
            }
        }
        if candidateIndices.isEmpty {
            NSLog("[DIAG] Matcher.matchScoped shabadIds=\(shabadIds.count) no_candidates")
            return []
        }

        // Stage 1: length-softened partial_ratio over the scoped
        // candidates. The softened score `effective = pr * sqrt(lf)`
        // is what selects the top-50 for Stage 2 AND becomes the
        // `partial` input to Stage 2's `final = partial * coverage`.
        // This means short trivial-substring matches get penalised
        // both for ranking and for Stage 2 throughput, matching the
        // ranking the prefilter would have given a full-corpus match.
        let stage1Start = Date()
        struct ScoredCandidate {
            let effective: Double
            let rawPartial: Double
            let lengthFactor: Double
            let index: Int
        }
        var stage1: [ScoredCandidate] = []
        stage1.reserveCapacity(candidateIndices.count)
        for i in candidateIndices {
            let lineText = normalizedTexts[i]
            if lineText.isEmpty { continue }
            let pr = StringMetrics.partialRatio(normalised, lineText)
            let lLen = lineText.count
            let lf = Double(min(qLen, lLen)) / Double(max(qLen, lLen))
            let effective = pr * sqrt(lf)
            stage1.append(ScoredCandidate(
                effective: effective,
                rawPartial: pr,
                lengthFactor: lf,
                index: i
            ))
        }
        stage1.sort { $0.effective > $1.effective }
        let candidates = stage1.prefix(Self.candidatePool)
        let stage1Ms = Int(Date().timeIntervalSince(stage1Start) * 1000)

        // Stage 2: rescore by softened_partial × token_coverage.
        let stage2Start = Date()
        var rescored: [(score: Double, partial: Double, coverage: Double, lengthFactor: Double, index: Int)] = []
        rescored.reserveCapacity(candidates.count)
        for cand in candidates {
            let cov = tokenCoverage(queryLongTokens: qLong, candidateTokens: tokens[cand.index])
            let final = cand.effective * cov
            rescored.append((final, cand.effective, cov, cand.lengthFactor, cand.index))
        }
        rescored.sort { $0.score > $1.score }
        let stage2Ms = Int(Date().timeIntervalSince(stage2Start) * 1000)
        let totalMs = Int(Date().timeIntervalSince(totalStart) * 1000)

        let topScore = rescored.first.map { String(format: "%.1f", $0.score) } ?? "n/a"
        NSLog("[DIAG] Matcher.matchScoped shabadIds=\(shabadIds.count) candidates=\(candidateIndices.count) topScore=\(topScore) stage1Ms=\(stage1Ms) stage2Ms=\(stage2Ms) totalMs=\(totalMs)")

        // TOP10 diagnostic (mirrors matchByFirstLetters' top-10 log).
        // Shows partial / coverage / lengthFactor / effective / ang
        // per candidate so on-device traces can pin a low topScore
        // back to either the partial_ratio, the coverage, or the
        // length penalty.
        let top10 = Array(rescored.prefix(10))
        let log10 = top10.enumerated().map { (idx, r) -> String in
            let line = lines[r.index]
            return "[\(idx + 1)] pr=\(String(format: "%.1f", r.partial)) cov=\(String(format: "%.2f", r.coverage)) lf=\(String(format: "%.2f", r.lengthFactor)) eff=\(String(format: "%.1f", r.score)) ang=\(line.ang) lineId=\(line.id)"
        }.joined(separator: " | ")
        NSLog("[DIAG] Matcher.matchScoped TOP10: \(log10)")

        return rescored.prefix(topN).map { entry in
            Match(
                line: lines[entry.index],
                score: entry.score,
                partialRatio: entry.partial,
                coverage: entry.coverage
            )
        }
    }

    public func match(_ query: String, topN: Int = 5) -> [Match] {
        let totalStart = Date()
        let normalised = normalize(query)
        if normalised.isEmpty { return [] }
        let qLong = longTokens(normalised)
        let qTokens = normalised.split(separator: " ").map { String($0) }
        let qFL = Self.firstLettersOf(tokens: qTokens)

        // Stage 0: first-letters pre-filter.
        // Keeps the top ``prefilterPoolCap`` corpus lines by
        // partial_ratio(qFL, lineFL). For queries with too few first-letters
        // to discriminate (<3 chars), fall back to the full corpus — the
        // original Stage 1 behaviour.
        // Brief #8.4 Bug 2: cancellation checks at stage boundaries
        // so RaagiModeEngine can abort an obsolete Tier 3 task whose
        // result was already superseded by a newer utterance's Tier
        // 1 / Tier 2 hit. Each check is one read of a thread-local;
        // costs nothing when not cancelled.
        if Task.isCancelled {
            NSLog("[DIAG] Matcher.match aborted due to Task.isCancelled at stage=0_start")
            return []
        }

        let prefilterStart = Date()
        let candidateIndices: [Int]
        let usedPrefilter: Bool
        if qFL.count >= Self.prefilterMinQueryFL {
            // Length-aware softening (added 2026-06-23) — same rationale
            // as matchByFirstLetters: a short Pankti FL substring-
            // matching a long query FL trivially scores 100, which can
            // crowd out honest length-matched candidates from the top
            // prefilterPoolCap. Sqrt(lf) penalty keeps the recall
            // property strong (target line stays in top 1500) while
            // making the prefilter behave more like the Python
            // canonical's no-prefilter full-scan baseline.
            let qFLLen = qFL.count
            var scored: [(score: Double, index: Int)] = []
            scored.reserveCapacity(firstLetters.count)
            for (i, lineFL) in firstLetters.enumerated() {
                // Periodic cancellation check inside the 56K-line
                // hot loop — the prefilter is the longest single
                // stage so a fast cancel here saves the most.
                if i % 5_000 == 0 && Task.isCancelled {
                    NSLog("[DIAG] Matcher.match aborted due to Task.isCancelled at stage=0_prefilter line=\(i)")
                    return []
                }
                if lineFL.isEmpty { continue }
                let pr = StringMetrics.partialRatio(qFL, lineFL)
                let lLen = lineFL.count
                let lf = Double(min(qFLLen, lLen)) / Double(max(qFLLen, lLen))
                let effective = pr * sqrt(lf)
                scored.append((effective, i))
            }
            // Partial sort by score desc; keep top prefilterPoolCap.
            scored.sort { $0.score > $1.score }
            if scored.isEmpty {
                // Defensive: every corpus line had an empty FL → full scan.
                candidateIndices = Array(0..<normalizedTexts.count)
                usedPrefilter = false
            } else {
                candidateIndices = scored.prefix(Self.prefilterPoolCap).map(\.index)
                usedPrefilter = true
            }
        } else {
            candidateIndices = Array(0..<normalizedTexts.count)
            usedPrefilter = false
        }
        let prefilterMs = Int(Date().timeIntervalSince(prefilterStart) * 1000)

        if Task.isCancelled {
            NSLog("[DIAG] Matcher.match aborted due to Task.isCancelled at stage=1_start")
            return []
        }

        // Stage 1: top-K candidates by full partial_ratio (over the
        // pre-filtered set, not the full 60K corpus).
        let stage1Start = Date()
        var stage1: [(score: Double, index: Int)] = []
        stage1.reserveCapacity(candidateIndices.count)
        for (idx, i) in candidateIndices.enumerated() {
            // Stage 1 typically iterates 1500 candidates on iPhone —
            // a single cancellation check every 500 keeps the worst-
            // case post-cancel runtime under ~50 ms.
            if idx % 500 == 0 && Task.isCancelled {
                NSLog("[DIAG] Matcher.match aborted due to Task.isCancelled at stage=1 candidate=\(idx)/\(candidateIndices.count)")
                return []
            }
            let pr = StringMetrics.partialRatio(normalised, normalizedTexts[i])
            stage1.append((pr, i))
        }
        stage1.sort { $0.score > $1.score }
        let candidates = stage1.prefix(Self.candidatePool)
        let stage1Ms = Int(Date().timeIntervalSince(stage1Start) * 1000)

        if Task.isCancelled {
            NSLog("[DIAG] Matcher.match aborted due to Task.isCancelled at stage=2_start")
            return []
        }

        // Stage 2: rescore by partial_ratio × token_coverage
        let stage2Start = Date()
        var rescored: [(score: Double, partial: Double, coverage: Double, index: Int)] = []
        rescored.reserveCapacity(candidates.count)
        for (partial, index) in candidates {
            let cov = tokenCoverage(queryLongTokens: qLong, candidateTokens: tokens[index])
            let final = partial * cov
            rescored.append((final, partial, cov, index))
        }
        rescored.sort { $0.score > $1.score }
        let stage2Ms = Int(Date().timeIntervalSince(stage2Start) * 1000)
        let totalMs = Int(Date().timeIntervalSince(totalStart) * 1000)

        NSLog("[DIAG] Matcher.match totalLines=\(normalizedTexts.count) qFL=\"\(qFL)\" usedPrefilter=\(usedPrefilter) stage1Candidates=\(candidateIndices.count) cap=\(Self.prefilterPoolCap) (restored from 600 in #8.6) prefilterMs=\(prefilterMs) stage1Ms=\(stage1Ms) stage2Ms=\(stage2Ms) totalMs=\(totalMs)")

        return rescored.prefix(topN).map { entry in
            Match(
                line: lines[entry.index],
                score: entry.score,
                partialRatio: entry.partial,
                coverage: entry.coverage
            )
        }
    }

    // ---------------------------------------------------------------------

    func longTokens(_ normalised: String) -> [String] {
        normalised.split(separator: " ")
            .map(String.init)
            .filter { $0.count >= Self.longTokenMin }
    }

    func tokenCoverage(queryLongTokens: [String], candidateTokens: [String]) -> Double {
        if queryLongTokens.isEmpty || candidateTokens.isEmpty { return 0.0 }

        var matched = 0
        for qt in queryLongTokens {
            var best = 0.0
            for ct in candidateTokens {
                let r = StringMetrics.ratio(qt, ct)
                if r > best { best = r }
                if best >= 100.0 { break }
            }
            if best >= Self.tokenMatchThreshold { matched += 1 }
        }

        let raw = Double(matched) / Double(queryLongTokens.count)
        // Length factor: queries with < MIN long tokens scale down
        let lengthFactor = min(1.0,
            Double(queryLongTokens.count) / Double(Self.minLongTokensForFullConfidence)
        )
        return raw * lengthFactor
    }
}
