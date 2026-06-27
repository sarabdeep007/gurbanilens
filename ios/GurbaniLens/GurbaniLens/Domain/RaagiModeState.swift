import Foundation
import GurbaniLensCore

/// State machine for Raagi Mode — continuous-listening UX where the
/// app follows a Raagi performing kirtan, switches between shabads as
/// they're recited, and highlights the active pangti.
///
/// **Differences from the quick-search state machine** (VoiceSearch-
/// Session): no `.idle` → `.recording` → `.processing` → `.done`
/// terminal. Raagi Mode loops continuously: each utterance plays
/// through `.listening` → `.recording` → `.processing` → `.displaying`,
/// then returns to `.listening` for the next utterance. `.displaying`
/// is sticky — when the next utterance is mid-pipeline we DON'T drop
/// the shabad from screen; we keep it visible until a new match
/// arrives (or the utterance is rejected / a jaikara fires).
///
/// Jaikara hits are surfaced via a separate `jaikaraBanner: String?`
/// @Published property on the engine — they're an overlay, not a
/// state replacement, so the underlying shabad stays on screen behind
/// the banner.
public enum RaagiModeState: Equatable, Sendable {
    /// Engine constructed but not yet started, or stopped after
    /// running. UI shows the "ਪਾਠ ਸ਼ੁਰੂ ਕਰੋ" entry prompt.
    case idle

    /// Mic is on, VAD has NOT detected speech yet. UI shows the
    /// waveform in idle (gray-blue) plus the listening hint.
    case listening

    /// VAD detected speech — capturing audio for the current
    /// utterance. UI animates the waveform in vivid colour.
    case recording

    /// Audio capture stopped (VAD silence trail or stream close).
    /// /transcribe + matcher pipeline in flight. `text` is the
    /// Gurmukhi transcript (when it arrives).
    case processing(text: String)

    /// Showing a shabad with the matched pangti highlighted. `lineId`
    /// is the SGGS Line.id of the currently-highlighted pangti.
    /// Subsequent matches that resolve to the SAME shabadId update
    /// `lineId` (highlight moves, auto-scroll fires); matches to a
    /// DIFFERENT shabadId replace `shabad` entirely (cache hit /
    /// miss handled by ShabadCache).
    case displaying(shabad: FullShabad, lineId: String)

    /// Pipeline error — engine logs + auto-retries after a short
    /// backoff. UI may show a small "..." indicator.
    case error(String)

    public static func == (lhs: RaagiModeState, rhs: RaagiModeState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.listening, .listening), (.recording, .recording):
            return true
        case (.processing(let a), .processing(let b)):
            return a == b
        case (.displaying(let sa, let la), .displaying(let sb, let lb)):
            // Compare shabad by id only (lines never change for same
            // shabadId); compare current line by id.
            return sa.id == sb.id && la == lb
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// One shabad's worth of pangti+rahao lines, in display order. Built
/// by ``ShabadCache`` from the corpus's `shabadLines(shabadId:)` query
/// with a Pankti/Rahao line_type filter. Sirlekh / Manglacharan are
/// filtered out — those are section headers that aren't useful in
/// Raagi-follow display.
public struct FullShabad: Sendable, Equatable, Identifiable {
    /// SGGS Shabad ID (same as Match.line.shabadId from the matcher).
    public let id: String
    /// Display lines in order. First line's `ang` gives the page
    /// number for headers; pangti counts span the shabad.
    public let lines: [Line]

    public init(id: String, lines: [Line]) {
        self.id = id
        self.lines = lines
    }

    /// Title shown above the shabad — uses the first line's Ang for
    /// reference. The actual title text (e.g. "ਆਸਾ ਮਹਲਾ ੧") is
    /// usually in a Sirlekh/Manglacharan line that we filter out, so
    /// the Raagi-mode UI uses "Ang N" as a simple anchor.
    public var headerLabel: String {
        guard let first = lines.first else { return "" }
        return "Ang \(first.ang)"
    }

    public static func == (lhs: FullShabad, rhs: FullShabad) -> Bool {
        // Identity comparison only — the line arrays for a given
        // shabadId never change, so comparing IDs avoids walking the
        // (sometimes long) arrays on every SwiftUI diff.
        lhs.id == rhs.id
    }
}
