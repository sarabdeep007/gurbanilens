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

    // Reactive provider-label inputs. The caption updates whenever the
    // user changes any of these in Settings (rare while listening, but
    // harmless to wire up reactively).
    @AppStorage("settings.asrProvider") private var asrProviderRaw: String = ASRProviderId.whisperKit.rawValue
    @AppStorage("settings.whisperModel") private var whisperModelRaw: String = WhisperModel.medium.rawValue
    @AppStorage("settings.disableWhisper") private var disableWhisper: Bool = false

    var body: some View {
        Group {
            if case .processing(let text) = session.state {
                searchingView(text: text)
            } else {
                listeningView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationTitle(navTitle)
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

    // MARK: - Body branches

    private var listeningView: some View {
        VStack(spacing: 0) {
            // Active-provider caption — tiny strip at the very top so
            // the user always knows which ASR backend is running.
            providerCaption
                .padding(.top, 6)

            // Brief #7 (2026-06-25): the partial-transcript box +
            // "ਸੁਣ ਰਿਹਾ ਹਾਂ…" placeholder reinforced false transcripts
            // and looked unprofessional. Replaced with a real-time
            // waveform + state label. The waveform IS the visual
            // feedback now.
            waveformHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)

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
    }

    /// Replaces the old transcriptHeader. WaveformView animates with
    /// the current `bufferEnergy`; colour intensifies when Silero has
    /// detected speech (state `.recording`). When the WhisperKit model
    /// is downloading on first launch, swaps in the progress UI
    /// instead.
    @ViewBuilder
    private var waveformHeader: some View {
        if let progress = downloadProgress {
            modelDownloadHeader(progress: progress)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            let recording: Bool = {
                if case .recording = session.state { return true } else { return false }
            }()
            VStack(spacing: 8) {
                WaveformView(amplitude: bufferEnergy, isActive: recording)
                Text(recording ? "Recording…" : "Listening…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Center-screen "searching" UI shown while ``Matcher.match`` is
    /// running on the accumulated transcript. The bottom Stop pill is
    /// intentionally absent here — capture is already stopped; there's
    /// nothing to interrupt. The Cancel toolbar button still works if
    /// the user wants to bail before the matcher finishes.
    private func searchingView(text: String) -> some View {
        VStack(spacing: 0) {
            providerCaption
                .padding(.top, 6)
            VStack(spacing: 16) {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.primary)
                Text("ਖੋਜ ਰਹੇ ਹਾਂ…")
                    .font(.headline)
                    .foregroundColor(Theme.onSurface)
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundColor(Theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Caption strip identifying the active ASR backend. Recomputes
    /// reactively via @AppStorage so toggling settings reflects
    /// without having to leave + re-enter the screen.
    private var providerCaption: some View {
        HStack {
            Spacer()
            Text("Using: \(activeProviderLabel)")
                .font(.system(size: 11))
                .foregroundColor(Theme.onSurfaceVariant.opacity(0.85))
            Spacer()
        }
    }

    /// Human-readable name of the actually-running provider. When a
    /// session is live, reads the truth from `session.providerLabel`
    /// (set in VoiceSearchSession.startStreaming from the running
    /// StreamingASR's displayName). When idle / pre-session, falls
    /// back to a hint computed from @AppStorage so the user has
    /// something to look at before tapping Listen.
    ///
    /// Reads runtime first to fix Deep's 2026-06-24 bug where the
    /// caption flipped to "Sarvam" mid-session while Gemini was still
    /// the cached StreamingASR's actual backend.
    private var activeProviderLabel: String {
        if !session.providerLabel.isEmpty {
            return session.providerLabel
        }
        return previewProviderLabel
    }

    /// Pre-session hint — applies the same substitution chain
    /// `StreamingASR.init` will apply (cloud-off → whisperKit;
    /// disableWhisper → sarvam) so the caption doesn't lie before
    /// the user even taps Listen.
    private var previewProviderLabel: String {
        // Default true to match StreamingASR.init + SettingsScreen
        // @AppStorage default flipped 2026-06-25.
        let cloudEnabled = (UserDefaults.standard.object(forKey: "settings.cloudEnabled") as? Bool) ?? true
        let raw = ASRProviderId(rawValue: asrProviderRaw) ?? .gurbanilensCloud
        var effective = raw
        if !cloudEnabled, effective == .sarvam || effective == .gemini || effective == .dual || effective == .gurbanilensCloud {
            effective = .whisperKit
        }
        // Mirror StreamingASR.init's disableWhisper substitution
        // target (now .gurbanilensCloud after the 2026-06-25 cloud
        // refresh).
        if disableWhisper, effective == .whisperKit || effective == .dual, cloudEnabled {
            effective = .gurbanilensCloud
        }
        switch effective {
        case .whisperKit:
            let m = WhisperModel(rawValue: whisperModelRaw) ?? .medium
            return "Whisper-\(m.shortDisplayName)"
        case .sarvam:
            return disableWhisper ? "Sarvam (Whisper disabled)" : "Sarvam Saaras-v3"
        case .gemini:
            return "Gemini 2.5 Flash"
        case .dual:
            return "Whisper-small + Sarvam (Dual)"
        case .gurbanilensCloud:
            return "GurbaniLens Cloud"
        }
    }

    private var navTitle: String {
        if case .processing = session.state { return "Searching…" }
        return "Listening…"
    }

    // MARK: - Header

    /// First-launch WhisperKit model-download progress UI. Shown
    /// in-place of the waveform via the `waveformHeader` ViewBuilder
    /// when `downloadProgress` is non-nil.
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
                .font(.notoSerifGurmukhi(18, weight: .medium))
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
        // line.gurmukhi is Anmol Lipi from the BaniDB-derived corpus —
        // iOS's system font has no Anmol Lipi glyphs, so converting
        // to proper Unicode Gurmukhi at display time is the price we
        // pay until the corpus is pre-converted at build time.
        // See GurbaniLensCore/AnmolLipi.swift (anvaad-js port).
        return Gurmukhi.fromAnmolLipi(line.gurmukhi)
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
        case .recording(let t, _, _):
            return t
        case .processing(let t):
            return t
        default:
            return ""
        }
    }

    private var liveMatches: [Match] {
        if case .recording(_, let m, _) = session.state { return m }
        return []
    }

    /// True when the mic is on — Brief #7 split this into two states
    /// (.listening = VAD waiting, .recording = VAD active) but the UI
    /// shows the "we're capturing" affordances (Stop button, etc.)
    /// for both.
    private var isListening: Bool {
        switch session.state {
        case .listening, .recording: return true
        default: return false
        }
    }

    private var stopLabel: String {
        switch session.state {
        case .processing: return "Searching…"
        case .done:       return "Done"
        default:          return "Stop"
        }
    }

    /// Current buffer energy — drives waveform amplitude when the
    /// WaveformView ships in the follow-up commit. Reads from either
    /// .listening or .recording payload.
    private var bufferEnergy: Float {
        switch session.state {
        case .listening(let e): return e
        case .recording(_, _, let e): return e
        default: return 0
        }
    }
}
