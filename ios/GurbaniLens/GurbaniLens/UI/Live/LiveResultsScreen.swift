import SwiftUI
import GurbaniLensCore

/// Phase A v2 live search-as-you-speak screen. **Minimal foundation —
/// Phase B will add the sticky animated header, VU underline, confirmed/
/// unconfirmed text styling, list-diff animations, etc.** Per the Phase A
/// dispatch the goal is correctness + plumbing, not polish.
///
/// Shows:
///   - the running transcript text (confirmed + unconfirmed concatenated)
///   - a plain List of liveMatches (Ang · Pankti · transliteration)
///   - a Stop button → `onStop()` triggers commit + full fuzzy match
///   - Cancel in the nav bar → `onCancel()` returns home
///   - Tap a row → `onCommit(match)` runs commit then navigates to the
///     tapped match's Shabad screen
struct LiveResultsScreen: View {
    @ObservedObject var session: VoiceSearchSession
    let onStop: () -> Void
    let onCancel: () -> Void
    let onCommit: (Match) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Plain header — Phase B turns this into the sticky animated
            // transcript with confirmed/unconfirmed colour split + VU bar.
            transcriptHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)

            // Live results list. Phase B replaces with a LazyVStack +
            // SwiftUI .transition + .animation for smooth row insert/move
            // animations as the matcher refreshes.
            List {
                ForEach(liveMatches, id: \.line.id) { match in
                    Button {
                        onCommit(match)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ang \(match.line.ang)" + (match.line.pangti.map { " · Pankti \($0)" } ?? ""))
                                .font(.system(size: 13))
                                .foregroundColor(Theme.onSurfaceVariant)
                            Text(match.line.transliterationEn ?? match.line.gurmukhi)
                                .font(.system(size: 16))
                                .foregroundColor(Theme.onSurface)
                                .multilineTextAlignment(.leading)
                            Text(String(format: "FL score %.0f", match.score))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            // Stop button. Always enabled while we're listening / committing.
            Button(action: onStop) {
                Text(stopLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.primary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationTitle("Listening…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onCancel) {
                    Image(systemName: "xmark").foregroundColor(Theme.onBackground)
                }.accessibilityLabel("Cancel")
            }
        }
    }

    // MARK: - Subviews

    private var transcriptHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You said:")
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
            Text(transcriptText.isEmpty ? "(listening…)" : transcriptText)
                .font(.system(size: 17, design: .monospaced))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: - Derived state

    /// Header text. Bug H — translate Devanagari source from
    /// `.listening` into Gurmukhi at render time. `.committing.query`
    /// is already Gurmukhi (transliterated in VoiceSearchSession.commit
    /// before transitioning).
    private var transcriptText: String {
        switch session.state {
        case .listening(let c, let u, _, _):
            let cG = Gurmukhi.fromDevanagari(c)
            let uG = Gurmukhi.fromDevanagari(u)
            return (cG + " " + uG).trimmingCharacters(in: .whitespacesAndNewlines)
        case .committing(let q):
            return q
        default:
            return ""
        }
    }

    private var liveMatches: [Match] {
        if case .listening(_, _, let m, _) = session.state { return m }
        return []
    }

    private var stopLabel: String {
        switch session.state {
        case .committing: return "Searching…"
        case .done:       return "Done"
        default:          return "Stop"
        }
    }
}
