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
        let built = FullShabad(id: id, lines: filtered)
        shabads[id] = built
        NSLog("[DIAG] ShabadCache MISS id=\(id) fetchedLines=\(raw.count) keptLines=\(filtered.count) cachedCount=\(shabads.count)")
        return built
    }

    /// Drop everything. Called when Raagi Mode is exited so the next
    /// session starts fresh.
    public func clear() {
        let dropped = shabads.count
        shabads.removeAll(keepingCapacity: true)
        NSLog("[DIAG] ShabadCache cleared (dropped \(dropped) shabads)")
    }

    /// Diagnostic: number of cached shabads (used for the bottom-of-
    /// screen "n in memory" status indicator if we choose to surface
    /// it later).
    public var count: Int {
        shabads.count
    }
}
