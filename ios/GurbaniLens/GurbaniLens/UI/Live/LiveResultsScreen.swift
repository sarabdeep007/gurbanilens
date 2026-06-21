import SwiftUI
import GurbaniLensCore

/// **Phase A.3 reset (2026-06-21).** Rebuilt for the Amrit-Kirtan-style
/// layout Deep flagged: small bounded transcript area at the top, the
/// candidate results list as the dominant content area, single Stop
/// pill at the bottom. The previous Phase A header had no max-height
/// and grew with concatenated junk, pushing the results list below the
/// screen.
///
/// Layout:
///   ┌────────────────────────────────┐
///   │ ✕                              │   nav bar — cancel
///   ├────────────────────────────────┤
///   │ ਸ੍ਰੀ ਆਸਾ ਜੀ                    │   bounded scrollable header
///   │ ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮ            │   max 120pt; scrolls to bottom
///   ├────────────────────────────────┤   on new content
///   │ N Shabads found                │   count line
///   ├────────────────────────────────┤
///   │ Ang … Pankti …                 │   List (LazyVStack), takes
///   │ ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੁ           │   remaining vertical space.
///   │                                │   Empty state row when no
///   │ Ang … Pankti …                 │   matches yet.
///   │ ਆਸਾ ਮਹਲਾ ੧                   │
///   │                                │
///   │ …                              │
///   ├────────────────────────────────┤
///   │ [        Stop        ]         │   full-width pill
///   └────────────────────────────────┘
struct LiveResultsScreen: View {
    @ObservedObject var session: VoiceSearchSession
    /// Phase A.4a — Whisper model download progress (nil unless a
    /// download is in flight). When non-nil, the transcript header
    /// shows a `ProgressView` instead of the listening placeholder.
    let downloadProgress: Float?
    let onStop: () -> Void
    let onCancel: () -> Void
    let onCommit: (Match) -> Void

    private static let headerMaxHeight: CGFloat = 120

    /// Phase A.4b — debug Compare button, unlocked by 5 taps on the
    /// Settings → Version footer. When false the toolbar button is
    /// hidden entirely (production users never see it).
    @AppStorage("settings.debugCompareEnabled") private var debugCompareEnabled: Bool = false
    @State private var showCompareSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Bounded transcript header.
            transcriptHeader
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.top, 8)

            // Match count above list (Amrit-Kirtan-style "N Shabads found").
            matchCountStrip
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Results list takes the remaining vertical space.
            if liveMatches.isEmpty {
                listeningEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
            }

            // Stop button — bottom-pinned full-width pill.
            stopButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
            if debugCompareEnabled {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showCompareSheet = true }) {
                        Image(systemName: "rectangle.split.3x1")
                            .foregroundColor(Theme.onBackground)
                    }.accessibilityLabel("Compare providers (debug)")
                }
            }
        }
        .sheet(isPresented: $showCompareSheet) {
            NavigationStack {
                CompareScreen(onDismiss: { showCompareSheet = false })
            }
        }
    }

    // MARK: - Header

    private var transcriptHeader: some View {
        Group {
            if let progress = downloadProgress {
                // Phase A.4a: WhisperKit model is downloading. Swap the
                // listening placeholder for a progress UI.
                modelDownloadHeader(progress: progress)
            } else {
                liveTranscriptHeader
            }
        }
    }

    private func modelDownloadHeader(progress: Float) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloading voice model")
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant)
            Text(String(format: "%.0f%%", max(0, min(progress, 1)) * 100))
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(Theme.onSurface)
            ProgressView(value: max(0, min(Double(progress), 1)))
                .progressViewStyle(.linear)
                .tint(Theme.primary)
            Text("Only on first launch — subsequent searches are instant.")
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveTranscriptHeader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You said:")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.onSurfaceVariant)
                    Text(transcriptText.isEmpty ? "ਸੁਣ ਰਿਹਾ ਹਾਂ…" : transcriptText)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.onSurface)
                        .multilineTextAlignment(.leading)
                        .id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.headerMaxHeight)
            .onChange(of: transcriptText) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Match count

    private var matchCountStrip: some View {
        HStack {
            Text(matchCountLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.onSurfaceVariant)
            Spacer()
        }
    }

    private var matchCountLabel: String {
        let n = liveMatches.count
        if n == 0 {
            return isListening ? "Listening…" : "No matches yet"
        }
        return "\(n) Shabad\(n == 1 ? "" : "s") found"
    }

    // MARK: - Results list

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(liveMatches, id: \.line.id) { match in
                    Button {
                        onCommit(match)
                    } label: {
                        liveMatchRow(match)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func liveMatchRow(_ match: Match) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ang \(match.line.ang)" + (match.line.pangti.map { " · Pankti \($0)" } ?? ""))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                Spacer()
            }
            Text(rowGurmukhi(match.line))
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Theme.onSurface)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Prefer the Unicode Gurmukhi column once the Anvaad-augmented
    /// app DB lands; until then fall back to the raw `gurmukhi` column
    /// (Anmol Lipi, renders as Gurmukhi when the bundled font is
    /// active). The dispatch explicitly forbids `transliterationEn`
    /// here — Sangat want to see Gurmukhi, not Latin.
    private func rowGurmukhi(_ line: Line) -> String {
        if let unicode = line.gurmukhiUnicode, !unicode.isEmpty {
            return unicode
        }
        return line.gurmukhi
    }

    // MARK: - Empty state row

    private var listeningEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "ear")
                .font(.system(size: 28))
                .foregroundColor(Theme.onSurfaceVariant)
            Text("Listening for kirtan…")
                .font(.system(size: 15))
                .foregroundColor(Theme.onSurfaceVariant)
            Text("Speak a line of Gurbani.")
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Stop button

    private var stopButton: some View {
        Button(action: onStop) {
            Text(stopLabel)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.onPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.primary)
                .clipShape(Capsule())
        }
    }

    // MARK: - Derived state

    private var transcriptText: String {
        switch session.state {
        case .listening(let t, _, _):
            return t
        case .committing(let q):
            return q
        default:
            return ""
        }
    }

    private var liveMatches: [Match] {
        if case .listening(_, let m, _) = session.state { return m }
        return []
    }

    private var isListening: Bool {
        if case .listening = session.state { return true }
        return false
    }

    private var stopLabel: String {
        switch session.state {
        case .committing: return "Searching…"
        case .done:       return "Done"
        default:          return "Stop"
        }
    }
}
