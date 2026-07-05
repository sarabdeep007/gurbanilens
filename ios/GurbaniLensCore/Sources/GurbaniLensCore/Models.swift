import Foundation

/// A single line of SGGS — Pankti, Rahao, Sirlekh, or Manglacharan.
/// Mirrors core/gurbanilens/corpus.py:Line
public struct Line: Hashable, Sendable {
    public let id: String
    public let shabadId: String
    public let ang: Int
    public let pangti: Int?
    public let lineType: String?
    public let gurmukhi: String
    public let gurmukhiUnicode: String?
    public let transliterationEn: String?
    public let firstLetters: String?
    public let orderId: Int

    public init(
        id: String,
        shabadId: String,
        ang: Int,
        pangti: Int?,
        lineType: String?,
        gurmukhi: String,
        gurmukhiUnicode: String?,
        transliterationEn: String?,
        firstLetters: String?,
        orderId: Int
    ) {
        self.id = id
        self.shabadId = shabadId
        self.ang = ang
        self.pangti = pangti
        self.lineType = lineType
        self.gurmukhi = gurmukhi
        self.gurmukhiUnicode = gurmukhiUnicode
        self.transliterationEn = transliterationEn
        self.firstLetters = firstLetters
        self.orderId = orderId
    }
}

extension Line {
    /// Brief #9.24 Part 6: find the section-header line that most
    /// recently precedes a given orderId. Given an array of
    /// candidates (typically the Sirlekh lines of a shabad), returns
    /// the one with the highest `orderId` that is still ≤ the
    /// reference. Nil when the list is empty or every candidate is
    /// past `referenceOrderId`.
    ///
    /// Order-agnostic on the input: internally does a single linear
    /// pass. Callers can pass the candidate list unordered.
    public static func nearestSectionHeader(
        from candidates: [Line],
        atOrderId referenceOrderId: Int
    ) -> Line? {
        var best: Line?
        for candidate in candidates {
            guard candidate.orderId <= referenceOrderId else { continue }
            if best == nil || candidate.orderId > best!.orderId {
                best = candidate
            }
        }
        return best
    }
}

/// A single match result from the Matcher.
/// Mirrors core/gurbanilens/matcher.py:Match
public struct Match: Hashable, Sendable {
    public let line: Line
    /// Combined score in 0–100 (partial_ratio × coverage).
    public let score: Double
    /// Raw partial_ratio (Indel-based partial substring match, 0–100).
    public let partialRatio: Double
    /// Fraction of long query tokens fuzzy-matched in the candidate (0–1).
    public let coverage: Double
}
