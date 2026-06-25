import SwiftUI
import GurbaniLensCore

/// v1 Results — transcript strip, confidence pill, top match card, alternates.
/// Mirrors `android/.../ui/results/ResultsScreen.kt`.
struct ResultsScreen: View {
    let result: SearchResult
    let onBack: () -> Void
    let onTryAgain: () -> Void
    let onOpenShabad: (Match) -> Void

    @State private var showAlternates: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcriptStrip
                .padding(.top, 8)
            confidencePill
                .padding(.top, 16)
            Spacer().frame(height: 16)

            if result.topConfidence.isNoMatch {
                // < 50 — matcher gave up. Surface transcript prominently;
                // don't auto-pick a top result. If we have any matches
                // at all (40-49 ish), show them as a "did you mean" list.
                noClearMatchState
            } else if let top = result.top {
                MatchCard(match: top, isTopMatch: true) { onOpenShabad(top) }
                if !result.alternates.isEmpty {
                    Spacer().frame(height: 24)
                    alternatesSection
                }
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationTitle("Search results")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").foregroundColor(Theme.onBackground)
                }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: onTryAgain) {
                    Image(systemName: "arrow.clockwise").foregroundColor(Theme.onBackground)
                }.accessibilityLabel("Try again")
            }
        }
    }

    private var transcriptStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You said:")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            Text(result.transcript.isEmpty ? "(no transcript)" : result.transcript)
                .font(.system(size: 17, design: .monospaced))
                .foregroundColor(Theme.onSurface)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var confidencePill: some View {
        let color: Color = {
            switch result.topConfidence {
            case .found:        return Theme.success
            case .bestMatch:    return Theme.success
            case .likelyMatch:  return Theme.warning
            case .didYouMean:   return Theme.warning
            case .noClearMatch: return Theme.error
            }
        }()
        let icon: String? = (result.topConfidence == .found) ? "checkmark.circle.fill" : nil
        return HStack(spacing: 8) {
            if let icon = icon {
                Image(systemName: icon).foregroundColor(color).font(.system(size: 18, weight: .semibold))
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Text(result.topConfidence.display)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(color)
        }
    }

    /// Heading + list of alternative matches, presentation varies by
    /// tier:
    ///   .found      → "Other possibilities" inside a disclosure
    ///                 (collapsed by default — top match is the answer)
    ///   .bestMatch  → "Other possibilities" inside a disclosure
    ///   .likelyMatch → "Did you mean…" inline (visible)
    ///   .didYouMean  → "Did you mean…" inline (visible)
    @ViewBuilder
    private var alternatesSection: some View {
        switch result.topConfidence {
        case .found, .bestMatch:
            DisclosureGroup(
                isExpanded: $showAlternates,
                content: {
                    LazyVStack(spacing: 8) {
                        ForEach(result.alternates, id: \.line.id) { alt in
                            MatchCard(match: alt, isTopMatch: false) { onOpenShabad(alt) }
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    Text("Other possibilities (\(result.alternates.count))")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant)
                }
            )
            .tint(Theme.onSurfaceVariant)
        case .likelyMatch, .didYouMean:
            Text("Did you mean…")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onSurfaceVariant)
            Spacer().frame(height: 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(result.alternates, id: \.line.id) { alt in
                        MatchCard(match: alt, isTopMatch: false) { onOpenShabad(alt) }
                    }
                }
            }
        case .noClearMatch:
            // Not reached — noClearMatch is handled separately above.
            EmptyView()
        }
    }

    /// Shown when the matcher's top score is below 50 — we don't claim
    /// a winner. Surfaces the transcript prominently so the user can
    /// tell whether ASR or matching was the failure.
    private var noClearMatchState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't find a clear match for what we heard.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onSurface)
            Text("Tap the retry button (top-right) to try again. The transcript above shows what we heard — if it's wrong, the ASR was the problem; if it looks close to your Pangti, the matcher couldn't find it in the corpus.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            if !result.matches.isEmpty {
                Text("Closest guesses:")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.top, 8)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(result.matches.prefix(3)), id: \.line.id) { alt in
                            MatchCard(match: alt, isTopMatch: false) { onOpenShabad(alt) }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No matches found.")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onBackground)
            Text("Try reciting more of the Pangti, or speak more clearly.")
                .font(.system(size: 16))
                .foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MatchCard: View {
    let match: Match
    let isTopMatch: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ang \(match.line.ang)" + (match.line.pangti.map { " · Pangti \($0)" } ?? ""))
                        .font(.system(size: 14))
                        .foregroundColor(Theme.onSurfaceVariant)
                    Spacer()
                    if let t = match.line.lineType {
                        Text(t)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.background)
                            .foregroundColor(Theme.onBackground)
                            .clipShape(Capsule())
                    }
                }
                Text(Self.rowGurmukhi(match.line))
                    .font(.notoSerifGurmukhi(isTopMatch ? 22 : 17,
                                             weight: isTopMatch ? .medium : .regular))
                    .foregroundColor(Theme.onSurface)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isTopMatch ? Theme.surfaceVariant : Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// Prefer Unicode Gurmukhi, fall back to anvaad-converted Anmol
    /// Lipi. `transliterationEn` is NEVER displayed in result rows —
    /// Sangat want Gurmukhi, not Latin (Deep's 2026-06-23 screenshots
    /// showed rows rendering as "ham rulate firate. koee baat na
    /// poochhataa;" because the previous order preferred
    /// transliterationEn). Mirrors `LiveResultsScreen.rowGurmukhi`.
    private static func rowGurmukhi(_ line: Line) -> String {
        if let unicode = line.gurmukhiUnicode, !unicode.isEmpty {
            return unicode
        }
        return Gurmukhi.fromAnmolLipi(line.gurmukhi)
    }
}
