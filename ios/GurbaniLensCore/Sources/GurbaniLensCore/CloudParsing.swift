import Foundation

/// Pure parsing + script-detection helpers shared by the iOS app's
/// cloud ASR providers (Sarvam, Gemini) so they can be unit-tested via
/// `swift test` against the `GurbaniLensCore` SPM target instead of
/// requiring an Xcode app-target test scheme.
///
/// All functions are free of network IO, free of `Bundle.main` reads,
/// and deterministic. The providers thin-wrap these helpers; the
/// transport (WebSocket, REST, multipart) is provider-specific and
/// lives in the app target.
public enum CloudParsing {

    // MARK: - Script detection

    public enum ScriptKind: String, Sendable, Equatable {
        case gurmukhi
        case devanagari
        case other
    }

    /// Codepoint-bucketed script detect: whichever of Gurmukhi
    /// (U+0A00..U+0A7F) or Devanagari (U+0900..U+097F) has the most
    /// scalars in `text` wins. Mixed text resolves to whichever side has
    /// the higher count; ties resolve to Gurmukhi (preserves Punjabi
    /// recitation in the common case where Sarvam emits a few
    /// Devanagari-cluster artefacts in otherwise-Gurmukhi output).
    /// Returns `.other` when there are no Indic codepoints.
    public static func detectScript(_ text: String) -> ScriptKind {
        var g = 0, d = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A00...0x0A7F: g += 1
            case 0x0900...0x097F: d += 1
            default: break
            }
        }
        if g == 0 && d == 0 { return .other }
        return g >= d ? .gurmukhi : .devanagari
    }

    // MARK: - Sanitisation

    /// Strip common transcription-prefix leaks ("Transcript:", "Text:")
    /// + a single pair of leading/trailing triple-backtick fences that
    /// the LLM sometimes wraps output in.
    public static func sanitize(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let dropPrefixes = [
            "Transcript:", "transcript:",
            "Text:", "text:",
            "Transcription:", "transcription:"
        ]
        for p in dropPrefixes where out.hasPrefix(p) {
            out = String(out.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.hasPrefix("```") {
            if let nl = out.firstIndex(of: "\n") {
                out = String(out[out.index(after: nl)...])
            } else {
                out = String(out.dropFirst(3))
            }
        }
        if out.hasSuffix("```") {
            out = String(out.dropLast(3))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sarvam transcript extraction

    /// Pull the transcript text out of a parsed Sarvam JSON envelope.
    /// Handles the streaming endpoint's documented shapes
    /// (`{transcript: ...}`, `{text: ...}`, `{data: {transcript: ...}}`,
    /// Google-Speech-style `{results: [{alternatives: [{transcript: ...}]}]}`)
    /// and returns nil when no plausible transcript field is present.
    public static func extractSarvamTranscript(from dict: [String: Any]) -> String? {
        if let s = dict["transcript"] as? String { return nilIfEmpty(sanitize(s)) }
        if let s = dict["text"] as? String { return nilIfEmpty(sanitize(s)) }
        if let data = dict["data"] as? [String: Any] {
            if let s = data["transcript"] as? String { return nilIfEmpty(sanitize(s)) }
            if let s = data["text"] as? String { return nilIfEmpty(sanitize(s)) }
        }
        if let results = dict["results"] as? [[String: Any]],
           let first = results.first,
           let alternatives = first["alternatives"] as? [[String: Any]],
           let alt = alternatives.first,
           let s = alt["transcript"] as? String { return nilIfEmpty(sanitize(s)) }
        return nil
    }

    // MARK: - Gemini response extraction

    /// Pull the text out of a Gemini `generateContent` JSON response.
    /// Returns nil if no `candidates[0].content.parts[].text` is
    /// present, or the parts joined to an empty string.
    public static func extractGeminiText(fromResponseJson data: Data) -> String? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let candidates = parsed["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return nil
        }
        let joined = parts.compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return nilIfEmpty(sanitize(joined))
    }

    // MARK: - Accumulator join (Gemini chunked transcripts)

    /// Concat the running accumulated transcript with the latest chunk,
    /// with cheap overlap deduplication so consecutive Gemini chunks
    /// (which each contain a complete transcript-so-far rather than an
    /// incremental delta) don't duplicate the tail words.
    public static func joinAccumulator(prev: String, next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return n }
        if n.isEmpty { return p }
        let tailLen = min(20, p.count)
        let tail = String(p.suffix(tailLen))
        if !tail.isEmpty && n.hasPrefix(tail) {
            return p + String(n.dropFirst(tail.count))
        }
        return p + " " + n
    }

    // MARK: - Internals

    private static func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
