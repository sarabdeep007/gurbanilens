import Foundation

/// Brief #9.23 Part 4: precomputed set of SGGS shabadIds that
/// participate in cross-shabad 3-gram clusters above the build-time
/// threshold. `SungModeAccumulatorStore` consults this set in LOCKED
/// state to apply a 0.5× multiplier on cross-shabad hits that land
/// on any of these shabads — the theory being that when a raagi
/// sings a common phrase like "har har naam" (250 shabads share
/// that 3-gram), a matcher hit on one of those 250 shabads is by
/// itself weak evidence, and shouldn't count the same as a hit on a
/// shabad with distinctive content.
///
/// Produced by `scripts/build_ambiguous_shabad_set.py`. See the
/// script header for the ambiguity criterion + threshold rationale.
public struct AmbiguousShabadSet: Equatable {
    /// Backing store. `contains` is O(1) via Set.
    private let shabadIds: Set<String>

    /// The build-time threshold recorded in the JSON. Diagnostic
    /// only — the engine doesn't consult it at runtime.
    public let threshold: Int
    /// The corpus SHA-256 the JSON was derived against. Used to
    /// detect a mismatched drop-in at runtime if desired.
    public let corpusHash: String

    public init(shabadIds: Set<String>, threshold: Int = 0, corpusHash: String = "") {
        self.shabadIds = shabadIds
        self.threshold = threshold
        self.corpusHash = corpusHash
    }

    /// O(1) membership check.
    public func contains(_ shabadId: String) -> Bool {
        shabadIds.contains(shabadId)
    }

    /// Count of shabads in the set. Diagnostic.
    public var count: Int { shabadIds.count }

    // MARK: - JSON loading

    private struct Payload: Decodable {
        let ambiguousShabadIds: [String]
        let threshold: Int?
        let corpusHash: String?
    }

    /// Decode the JSON produced by `build_ambiguous_shabad_set.py`.
    /// Throws `DecodingError` on malformed JSON.
    public static func load(fromJSON data: Data) throws -> AmbiguousShabadSet {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return AmbiguousShabadSet(
            shabadIds: Set(payload.ambiguousShabadIds),
            threshold: payload.threshold ?? 0,
            corpusHash: payload.corpusHash ?? ""
        )
    }
}
