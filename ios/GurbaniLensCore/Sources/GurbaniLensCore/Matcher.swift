import Foundation

/// Fuzzy Pangti matcher. Swift port of `core/gurbanilens/matcher.py:Matcher`.
/// Validated against `core/tests/portparity/test_vectors.json`.
///
/// Sendable: `Matcher` is immutable after init (`let` lines / normalizedTexts /
/// tokens), so it's safe to hand to a `Task.detached` from MainActor without
/// touching mutable state. We declare `@unchecked Sendable` to make that
/// explicit at the type level — the app target moves match() off MainActor
/// to keep the UI thread snappy on long queries.
public final class Matcher: @unchecked Sendable {
    // Thresholds — must match test_vectors.json#/thresholds
    public static let tokenMatchThreshold: Double = 55.0
    public static let longTokenMin: Int = 3
    public static let minLongTokensForFullConfidence: Int = 4
    public static let candidatePool: Int = 50

    public let lines: [Line]
    /// Normalised English transliteration for each indexed line.
    let normalizedTexts: [String]
    /// Pre-split tokens for each indexed line (avoids repeated split work).
    let tokens: [[String]]

    public init(corpus: Corpus) throws {
        var ls: [Line] = []
        var nt: [String] = []
        var ts: [[String]] = []
        for line in try corpus.allLines() {
            guard let translit = line.transliterationEn else { continue }
            let normalized = normalize(translit)
            if normalized.isEmpty { continue }
            ls.append(line)
            nt.append(normalized)
            ts.append(normalized.split(separator: " ").map { String($0) })
        }
        self.lines = ls
        self.normalizedTexts = nt
        self.tokens = ts
    }

    /// Convenience init for tests / future use that bypasses Corpus.
    public init(prebuilt: [(line: Line, normalised: String, tokens: [String])]) {
        self.lines = prebuilt.map(\.line)
        self.normalizedTexts = prebuilt.map(\.normalised)
        self.tokens = prebuilt.map(\.tokens)
    }

    public var count: Int { lines.count }

    public func match(_ query: String, topN: Int = 5) -> [Match] {
        let normalised = normalize(query)
        if normalised.isEmpty { return [] }
        let qLong = longTokens(normalised)

        // Stage 1: top-K candidates by partial_ratio
        var stage1: [(score: Double, index: Int)] = []
        stage1.reserveCapacity(normalizedTexts.count)
        for (i, text) in normalizedTexts.enumerated() {
            let pr = StringMetrics.partialRatio(normalised, text)
            stage1.append((pr, i))
        }
        // Partial sort: keep top CANDIDATE_POOL
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
