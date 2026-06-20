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
    /// Maximum candidates handed to Stage 1 after the first-letters filter.
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

    public init(corpus: Corpus) throws {
        var ls: [Line] = []
        var nt: [String] = []
        var ts: [[String]] = []
        var fl: [String] = []
        for line in try corpus.allLines() {
            guard let translit = line.transliterationEn else { continue }
            let normalized = normalize(translit)
            if normalized.isEmpty { continue }
            let toks = normalized.split(separator: " ").map { String($0) }
            ls.append(line)
            nt.append(normalized)
            ts.append(toks)
            fl.append(Self.firstLettersOf(tokens: toks))
        }
        self.lines = ls
        self.normalizedTexts = nt
        self.tokens = ts
        self.firstLetters = fl
    }

    /// Convenience init for tests / future use that bypasses Corpus.
    public init(prebuilt: [(line: Line, normalised: String, tokens: [String])]) {
        self.lines = prebuilt.map(\.line)
        self.normalizedTexts = prebuilt.map(\.normalised)
        self.tokens = prebuilt.map(\.tokens)
        self.firstLetters = prebuilt.map { Self.firstLettersOf(tokens: $0.tokens) }
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

    public func match(_ query: String, topN: Int = 5) -> [Match] {
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
        let candidateIndices: [Int]
        if qFL.count >= Self.prefilterMinQueryFL {
            var scored: [(score: Double, index: Int)] = []
            scored.reserveCapacity(firstLetters.count)
            for (i, lineFL) in firstLetters.enumerated() {
                if lineFL.isEmpty { continue }
                let s = StringMetrics.partialRatio(qFL, lineFL)
                scored.append((s, i))
            }
            // Partial sort by score desc; keep top prefilterPoolCap.
            scored.sort { $0.score > $1.score }
            if scored.isEmpty {
                // Defensive: every corpus line had an empty FL → full scan.
                candidateIndices = Array(0..<normalizedTexts.count)
            } else {
                candidateIndices = scored.prefix(Self.prefilterPoolCap).map(\.index)
            }
        } else {
            candidateIndices = Array(0..<normalizedTexts.count)
        }

        // Stage 1: top-K candidates by full partial_ratio (over the
        // pre-filtered set, not the full 60K corpus).
        var stage1: [(score: Double, index: Int)] = []
        stage1.reserveCapacity(candidateIndices.count)
        for i in candidateIndices {
            let pr = StringMetrics.partialRatio(normalised, normalizedTexts[i])
            stage1.append((pr, i))
        }
        stage1.sort { $0.score > $1.score }
        let candidates = stage1.prefix(Self.candidatePool)

        // Stage 2: rescore by partial_ratio × token_coverage
        var rescored: [(score: Double, partial: Double, coverage: Double, index: Int)] = []
        rescored.reserveCapacity(candidates.count)
        for (partial, index) in candidates {
            let cov = tokenCoverage(queryLongTokens: qLong, candidateTokens: tokens[index])
            let final = partial * cov
            rescored.append((final, partial, cov, index))
        }
        rescored.sort { $0.score > $1.score }

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
