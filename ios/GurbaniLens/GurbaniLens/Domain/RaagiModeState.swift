import Foundation
import GurbaniLensCore

/// **Audio state** for the Raagi Mode engine. Brief #8.1 (2026-06-27)
/// reshape: this used to be a single `RaagiModeState` enum that mixed
/// "what's the mic doing" with "is a shabad on screen". That coupling
/// caused the bug Deep saw on Brief #8's first test — between
/// utterances the engine flipped back to `.listening`, which the UI
/// rendered as the "ਪਾਠ ਸ਼ੁਰੂ ਕਰੋ" idle screen, blowing away the
/// previously-displayed shabad until the next match landed.
///
/// **Now**: this enum only describes the audio pipeline. The displayed
/// shabad is a SEPARATE sticky `@Published currentShabad: FullShabad?`
/// on the engine, plus `currentLineId: String?` for the highlight. The
/// shabad persists across audio-state cycles and only mutates on
/// confirmed match (or session exit).
public enum RaagiAudioState: Equatable, Sendable {
    /// Engine constructed / stopped. Bottom status bar is empty.
    case idle
    /// Mic on, VAD waiting for speech.
    case listening
    /// VAD detected speech — capturing.
    case recording
    /// Audio capture stopped (silence trail / explicit stop) and
    /// the /transcribe + matcher pipeline is in flight.
    case processing
    /// Pipeline error — engine logs + auto-retries on next loop
    /// iteration. Bottom status bar surfaces a brief hint.
    case error(String)

    public var displayLabel: String {
        switch self {
        case .idle:       return ""
        case .listening:  return "ਸੁਣ ਰਿਹਾ ਹਾਂ"
        case .recording:  return "ਰਿਕਾਰਡ"
        case .processing: return "ਖੋਜ ਰਿਹਾ ਹਾਂ"
        case .error:      return "ਮੁੜ ਕੋਸ਼ਿਸ਼…"
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
