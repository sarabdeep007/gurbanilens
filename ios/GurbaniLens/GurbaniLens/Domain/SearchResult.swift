import Foundation
import GurbaniLensCore

/// One round of voice-search → matcher → top-N. Used by Results + Shabad
/// screens. Mirrors `android/.../domain/SearchResult.kt`.
public struct SearchResult: Sendable {
    public let transcript: String
    public let matches: [Match]
    public let topConfidence: ConfidenceLabel

    public var top: Match? { matches.first }
    public var alternates: [Match] { Array(matches.dropFirst().prefix(4)) }

    public init(transcript: String, matches: [Match], topConfidence: ConfidenceLabel) {
        self.transcript = transcript
        self.matches = matches
        self.topConfidence = topConfidence
    }

    public static func from(transcript: String, matches: [Match]) -> SearchResult {
        // Use ambiguity-aware tier computation: when top and runner-up
        // are within 2 points, demote a high-confidence tier so the UI
        // doesn't claim "Found ✓" on a tie.
        let label: ConfidenceLabel = {
            guard let top = matches.first else { return .noClearMatch }
            let runnerUp = matches.dropFirst().first?.score
            return ConfidenceLabel.forScores(top: top.score, runnerUp: runnerUp)
        }()
        return SearchResult(transcript: transcript, matches: matches, topConfidence: label)
    }

    public static let empty = SearchResult(transcript: "", matches: [], topConfidence: .noClearMatch)
}
