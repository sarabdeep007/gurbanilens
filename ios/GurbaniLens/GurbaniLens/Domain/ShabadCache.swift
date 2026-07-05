import Foundation
import GurbaniLensCore

/// Process-scoped, session-bounded cache of full shabad text. Brief #8
/// Commit 2.
///
/// **Purpose.** During Raagi Mode the engine matches each utterance to
/// a shabad. Common case: the raagi sings several pangtis of the same
/// shabad in sequence, then bounces between a few shabads over the
/// course of the kirtan. The matcher returns a single matched line;
/// to render the full shabad we need every Pankti + Rahao for that
/// shabadId from the corpus.
///
/// The corpus is on-device SQLite (no network), so a fetch is "fast"
/// in human-perception terms. But on a 5–10 ms hardware budget per
/// utterance turnaround, doing a fresh query for the SAME shabad five
/// times in a row is silly — and Brief #8 explicitly says the cache
/// should be flexible / dynamic / no eviction during a session.
///
/// **Lifetime.** One instance lives for the duration of a Raagi Mode
/// session. `clear()` empties on session end (RaagiModeEngine.stop()).
/// Process exit drops everything.
///
/// **Lines filter.** Only `Pankti` + `Rahao` line types are kept.
/// Sirlekh / Manglacharan are corpus structural rows (section headers,
/// composer / raag labels) that aren't useful in Raagi-follow
/// display.
///
/// **Thread safety.** Actor-isolated. `shabad(forId:)` is async; the
/// engine awaits it from MainActor.
public actor ShabadCache {

    private let corpus: Corpus
    private var shabads: [String: FullShabad] = [:]
    /// Brief #9.7-iOS: per-pangti first-letter signatures, parallel
    /// to ``shabads``. Outer key is shabadId, inner key is lineId,
    /// value is the FL signature (one short String per word).
    /// Populated lazily on the same miss path that fills ``shabads``;
    /// dropped together in ``clear()``. Memory footprint is
    /// negligible (~10-50 lines × ~6-10 single-char strings per
    /// shabad).
    private var flSignatures: [String: [String: [String]]] = [:]
    /// Brief #9.16-iOS: per-shabad safely-unique starter map
    /// (letter → lineId). Populated on the same MISS path that fills
    /// `flSignatures`; dropped in ``clear()``. Powers the LOCKED-
    /// state fast path in StreamingRaagiModeEngine that commits on
    /// matchLen=1 when the letter is unambiguous within the shabad.
    private var safeStarters: [String: [String: String]] = [:]
    /// Brief #9.19-iOS: per-shabad safely-unique starter-bigram map
    /// (bigramKey → lineId). Populated on the same MISS path that
    /// fills `flSignatures` and `safeStarters`. Powers the Tier B
    /// fast path in StreamingRaagiModeEngine that commits on
    /// matchLen=2 for pangtis whose starter letter pair is unique
    /// within the shabad's consecutive-bigram universe.
    private var safeBigrams: [String: [String: String]] = [:]

    public init(corpus: Corpus) {
        self.corpus = corpus
    }

    /// Hit-or-miss lookup. Throws if the underlying corpus query
    /// fails (DB I/O error, missing shabadId, etc.). The engine
    /// catches and reverts to its sticky display fallback.
    public func shabad(forId id: String) throws -> FullShabad {
        if let cached = shabads[id] {
            NSLog("[DIAG] ShabadCache HIT id=\(id) cachedCount=\(shabads.count)")
            return cached
        }
        let raw = try corpus.shabadLines(shabadId: id)
        let filtered = raw.filter { line in
            let lt = line.lineType?.lowercased() ?? ""
            return lt == "pankti" || lt == "rahao"
        }
        // Brief #9.24 Part 6: preserve Sirlekh lines separately so
        // the display can show the current section header (Sloku,
        // Astpadi, Paurhi, etc.) above the visible pangti. Not
        // rendered inline — kept out of `lines` because RaagiView
        // iterates all lines assuming they are pankti/rahao content.
        let sirlekh = raw.filter { line in
            (line.lineType?.lowercased() ?? "") == "sirlekh"
        }
        let built = FullShabad(id: id, lines: filtered, sectionHeaders: sirlekh)
        shabads[id] = built

        // Brief #9.7: precompute FL signatures for every pangti.
        // Brief #9.11: when `gurmukhiUnicode` is nil (BaniDB v4 has
        // no `_unicode` column yet, so this is the common case), the
        // raw `gurmukhi` is AnmolLipi/GurbaniAkhar ASCII — converting
        // first letters to Unicode via the anvaad-js mapping is
        // required so FL sigs live in the same Unicode plane as the
        // ASR partials.
        var sigs: [String: [String]] = [:]
        sigs.reserveCapacity(filtered.count)
        for line in filtered {
            let extracted: [String]
            if let uni = line.gurmukhiUnicode, !uni.isEmpty {
                extracted = FirstLetterSignature.extract(uni)
            } else {
                extracted = FirstLetterSignature.extractFromAnmolLipi(line.gurmukhi)
            }
            sigs[line.id] = extracted
        }
        flSignatures[id] = sigs

        // Brief #9.16-iOS: precompute the safely-unique starter map
        // alongside the FL sigs. Same MISS path so the two stay in
        // lock-step for lifetime / clear().
        let corpusForUnique: [(lineId: String, fl: [String])] = sigs.map { ($0.key, $0.value) }
        let starters = FirstLetterSignature.safeUniqueStarters(corpus: corpusForUnique)
        safeStarters[id] = starters
        NSLog("[DIAG] ShabadCache safeUniqueStarters id=\(id) count=\(starters.count) letters=\(starters.keys.sorted().joined(separator: ","))")

        // Brief #9.19-iOS: precompute the safely-unique starter-bigram
        // map alongside the unigram map. Same MISS path; both stay
        // in lock-step for lifetime / clear().
        let bigrams = FirstLetterSignature.safeUniqueBigramStarters(corpus: corpusForUnique)
        safeBigrams[id] = bigrams
        NSLog("[DIAG] ShabadCache safeUniqueBigramStarters id=\(id) count=\(bigrams.count) keys=\(bigrams.keys.sorted().joined(separator: ","))")

        NSLog("[DIAG] ShabadCache MISS id=\(id) fetchedLines=\(raw.count) keptLines=\(filtered.count) flSigsComputed=\(sigs.count) safeStarters=\(starters.count) safeBigrams=\(bigrams.count) cachedCount=\(shabads.count)")
        return built
    }

    /// Brief #9.7-iOS: lookup of the precomputed FL signatures for a
    /// shabad. Returns nil if the shabad hasn't been fetched yet —
    /// caller (the streaming engine, typically) should call
    /// ``shabad(forId:)`` first to populate the cache. Cheap: pure
    /// dict lookup, no recompute.
    public func flSignatures(forId id: String) -> [String: [String]]? {
        flSignatures[id]
    }

    /// Brief #9.16-iOS: lookup of the precomputed safely-unique
    /// starter map for a shabad. Returns nil if the shabad hasn't
    /// been fetched yet.
    public func safeUniqueStarters(forId id: String) -> [String: String]? {
        safeStarters[id]
    }

    /// Brief #9.19-iOS: lookup of the precomputed safely-unique
    /// starter-bigram map for a shabad. Returns nil if the shabad
    /// hasn't been fetched yet.
    public func safeUniqueBigramStarters(forId id: String) -> [String: String]? {
        safeBigrams[id]
    }

    /// Brief #9.7-iOS: convenience that returns the FullShabad + its
    /// FL signatures in one actor hop. The streaming engine needs
    /// both on every lock/swap (the shabad for rendering, the
    /// signatures for fast pangti highlight); pairing them in one
    /// call saves a round-trip through the actor.
    ///
    /// Brief #9.16-iOS: extended to also return the safely-unique
    /// starter map for the LOCKED-state fast path in the engine.
    ///
    /// Brief #9.19-iOS: extended again to include the safely-unique
    /// starter-bigram map for the Tier B fast path.
    public func shabadWithFLSignatures(forId id: String) throws -> (
        shabad: FullShabad,
        signatures: [String: [String]],
        safeStarters: [String: String],
        safeBigrams: [String: String]
    ) {
        let s = try shabad(forId: id)
        let sigs = flSignatures[id] ?? [:]
        let starters = safeStarters[id] ?? [:]
        let bigrams = safeBigrams[id] ?? [:]
        return (s, sigs, starters, bigrams)
    }

    /// Drop everything. Called when Raagi Mode is exited so the next
    /// session starts fresh.
    public func clear() {
        let dropped = shabads.count
        let droppedSigs = flSignatures.count
        let droppedStarters = safeStarters.count
        let droppedBigrams = safeBigrams.count
        shabads.removeAll(keepingCapacity: true)
        flSignatures.removeAll(keepingCapacity: true)
        safeStarters.removeAll(keepingCapacity: true)
        safeBigrams.removeAll(keepingCapacity: true)
        NSLog("[DIAG] ShabadCache cleared (dropped \(dropped) shabads, \(droppedSigs) FL sigs, \(droppedStarters) safe-starter maps, \(droppedBigrams) safe-bigram maps)")
    }

    /// Diagnostic: number of cached shabads (used for the bottom-of-
    /// screen "n in memory" status indicator if we choose to surface
    /// it later).
    public var count: Int {
        shabads.count
    }
}
