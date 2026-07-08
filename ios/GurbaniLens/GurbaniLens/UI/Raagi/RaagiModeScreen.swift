import SwiftUI
import GurbaniLensCore

/// Root container for Raagi Mode. Brief #8 Commit 6 → reshaped in
/// Brief #8.1 for sticky display.
///
/// **Sticky display rule** (Brief #8.1). The primary content area
/// renders based on `engine.currentShabad`:
///   - non-nil → RaagiView or SangatView with `engine.currentLineId`
///                highlighted (per the view-mode @AppStorage)
///   - nil     → entry hint "ਪਾਠ ਸ਼ੁਰੂ ਕਰੋ"
///
/// The shabad NEVER drops between utterances. The audio pipeline
/// state (`engine.audioState`) only drives the bottom status bar.
///
/// **Composition**:
///   ┌────────────────────────────────────────────────────┐
///   │ X                          [Raagi]  [Sangat]       │ toolbar
///   ├────────────────────────────────────────────────────┤
///   │                                                    │
///   │         (RaagiView or SangatView or hint)          │
///   │                                                    │
///   │  + JaikaraBanner overlay (when activeJaikara)      │
///   │                                                    │
///   ├────────────────────────────────────────────────────┤
///   │  ▁▂▄▅▆▅▄▂▁   ਸੁਣ ਰਿਹਾ ਹਾਂ                          │ status
///   └────────────────────────────────────────────────────┘
struct RaagiModeScreen<Engine: RaagiModeViewModel>: View {
    @ObservedObject var engine: Engine
    let onExit: () -> Void
    /// Brief #9.26: cloud force-lock closure. Wired to the streaming
    /// engine's ``forceLockFromCloud`` via the AppNavGraph. Nil for
    /// the buffered engine — buffered mode doesn't surface the cloud
    /// so the closure is never called.
    let onForceLockFromCloud: ((String, String) -> Void)?
    /// Brief #9.26: async pangti-text fetcher for cloud rows. Wired
    /// to `StreamingRaagiModeEngine.fetchPangtiText`. Nil for the
    /// buffered engine — cloud never renders under buffered.
    let fetchPangtiTextForCloud: ((String, String) async -> String?)?

    init(
        engine: Engine,
        onExit: @escaping () -> Void,
        onForceLockFromCloud: ((String, String) -> Void)? = nil,
        fetchPangtiTextForCloud: ((String, String) async -> String?)? = nil
    ) {
        self.engine = engine
        self.onExit = onExit
        self.onForceLockFromCloud = onForceLockFromCloud
        self.fetchPangtiTextForCloud = fetchPangtiTextForCloud
    }

    @AppStorage("settings.raagiViewMode") private var viewModeRaw: String = "raagi"

    /// Brief #9.24 Part 5: view-layer peek state. When non-nil, the
    /// content area renders `shabad.lines[peekIndex]` instead of the
    /// engine's live `currentLineId`, and a "▶ Resume auto-follow"
    /// pill appears at the bottom. Auto-follow (engine + accumulator)
    /// keeps running behind the scenes — only the display is frozen.
    /// Tapping the pill clears peek and snaps back to whatever the
    /// engine is on at that moment.
    @State private var peekIndex: Int? = nil

    private var viewMode: ViewMode {
        ViewMode(rawValue: viewModeRaw) ?? .raagi
    }

    enum ViewMode: String, CaseIterable {
        case raagi
        case sangat

        var label: String {
            switch self {
            case .raagi: return "Raagi"
            case .sangat: return "Sangat"
            }
        }

        var iconName: String {
            switch self {
            case .raagi: return "list.bullet.rectangle.portrait"
            case .sangat: return "text.viewfinder"
            }
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomStatusBar
            }
            // Jaikara overlay sits above the main content but below
            // the toolbar so the X button stays tappable even when a
            // jaikara is on screen.
            VStack {
                Spacer().frame(height: 56)
                if let jaikara = engine.activeJaikara {
                    JaikaraBanner(text: jaikara)
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: engine.activeJaikara)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationBarHidden(true)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.onBackground)
                    .frame(width: 36, height: 36)
                    .background(Theme.surface.opacity(0.6), in: Circle())
            }
            .accessibilityLabel("Exit Raagi Mode")

            Spacer()

            HStack(spacing: 4) {
                ForEach(ViewMode.allCases, id: \.rawValue) { mode in
                    Button {
                        viewModeRaw = mode.rawValue
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.iconName)
                            Text(mode.label)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewMode == mode
                                ? Theme.primary.opacity(0.85)
                                : Color.clear
                        )
                        .foregroundColor(
                            viewMode == mode ? Theme.onPrimary : Theme.onSurfaceVariant
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Theme.surface.opacity(0.6), in: Capsule())
        }
    }

    // MARK: - Content (sticky display — driven by currentShabad)

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let shabad = engine.currentShabad, let lineId = engine.currentLineId {
                    // Sticky shabad on screen. Audio cycles in the bottom
                    // bar independently — this view doesn't react to
                    // .listening / .recording / .processing transitions
                    // at all.
                    let displayLineId = effectiveLineId(shabad: shabad, liveLineId: lineId)
                    shabadView(shabad: shabad, lineId: displayLineId)
                        // .id() on the shabadId means SwiftUI treats a
                        // cross-shabad swap as "different view", which
                        // makes the .transition(.opacity) actually fire
                        // the cross-fade. Without the .id, SwiftUI sees
                        // the same RaagiView/SangatView struct and just
                        // updates props.
                        .id("\(shabad.id)#\(viewMode.rawValue)")
                        .transition(.opacity)
                        .contentShape(Rectangle())
                        .gesture(peekSwipeGesture(shabad: shabad, liveLineId: lineId))
                } else if case let .visible(rows, partialsSeen) = engine.candidateCloud,
                          let onForceLock = onForceLockFromCloud,
                          let fetchText = fetchPangtiTextForCloud {
                    // Brief #9.26: streaming engine has entered the
                    // progressive-narrowing cloud path. Replaces the
                    // entry hint until the accumulator locks (auto),
                    // the user taps a row (manual), or the cloud is
                    // dismissed on any lock/re-lock/stop/toggle.
                    CandidateCloudView(
                        rows: rows,
                        partialsSeen: partialsSeen,
                        onForceLock: onForceLock,
                        onCancel: onExit,
                        fetchPangtiText: fetchText
                    )
                    .id("candidate-cloud")
                    .transition(.opacity)
                } else {
                    entryHint
                        .id("entry-hint")
                        .transition(.opacity)
                }
            }
            // Brief #9.24 Part 5: Resume-auto-follow pill. Only shown
            // when the user has swiped into peek mode. Tapping it
            // clears peek and lets the engine's live currentLineId
            // drive display again.
            if peekIndex != nil {
                resumePill
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: peekIndex)
        // .animation pulls SwiftUI into the .transition for both
        // (nil ↔ shabad) and (shabadA ↔ shabadB) swaps. 250 ms
        // matches the jaikara banner fade.
        .animation(.easeInOut(duration: 0.25), value: engine.currentShabad?.id)
        // Brief #9.26: also cross-fade when the cloud appears /
        // disappears (nil ↔ .visible ↔ .hidden) so the entry-hint /
        // cloud / shabad-body swaps stay smooth.
        .animation(.easeInOut(duration: 0.22), value: cloudVisibilityKey)
        // Cross-shabad swap clears peek — a different shabad has no
        // meaningful continuation of the previous peek index.
        .onChange(of: engine.currentShabad?.id) { _ in
            peekIndex = nil
        }
    }

    /// Brief #9.26: a stable animation key for the cloud state.
    /// Reduces `.visible(rows, partialsSeen)` to a lightweight
    /// value so SwiftUI's `.animation(value:)` only fires on
    /// meaningful (nil ↔ visible ↔ hidden) transitions, not on
    /// every row shuffle within an already-visible cloud (rows
    /// have their own animation in CandidateCloudView).
    private var cloudVisibilityKey: String {
        switch engine.candidateCloud {
        case .none: return "nil"
        case .some(.hidden): return "hidden"
        case .some(.visible): return "visible"
        }
    }

    // MARK: - Peek helpers (Brief #9.24 Part 5)

    private func effectiveLineId(shabad: FullShabad, liveLineId: String) -> String {
        guard let idx = peekIndex, shabad.lines.indices.contains(idx) else {
            return liveLineId
        }
        return shabad.lines[idx].id
    }

    /// Horizontal drag → advance / retreat peek by one line. Cheap
    /// enough to install on every render; SwiftUI keeps the gesture
    /// stable across view updates because the closure captures only
    /// value-type state.
    private func peekSwipeGesture(shabad: FullShabad, liveLineId: String) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Reject near-vertical drags so they don't fight
                // RaagiView's own scroll.
                guard abs(dx) > abs(dy) * 1.3 else { return }
                let currentIdx = peekIndex ??
                    (shabad.lines.firstIndex(where: { $0.id == liveLineId }) ?? 0)
                let delta = dx < 0 ? 1 : -1
                let next = max(0, min(shabad.lines.count - 1, currentIdx + delta))
                peekIndex = next
            }
    }

    private var resumePill: some View {
        Button {
            peekIndex = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Resume auto-follow")
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundColor(Theme.onPrimary)
            .background(
                Capsule().fill(Theme.primary.opacity(0.9))
            )
            .overlay(
                Capsule().stroke(Theme.onPrimary.opacity(0.2), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        // 44 pt min tap target satisfied by the padding above (30 pt
        // width + inline text expands well past 44 pt).
        .accessibilityLabel("Resume auto-follow")
    }

    @ViewBuilder
    private func shabadView(shabad: FullShabad, lineId: String) -> some View {
        switch viewMode {
        case .raagi:
            RaagiView(shabad: shabad, currentLineId: lineId)
        case .sangat:
            SangatView(shabad: shabad, currentLineId: lineId)
        }
    }

    private var entryHint: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "ear")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.onSurfaceVariant.opacity(0.7))
            Text("ਪਾਠ ਸ਼ੁਰੂ ਕਰੋ")
                .font(.notoSerifGurmukhi(28, weight: .medium))
                .foregroundColor(Theme.onSurface)
            Text("Begin reciting — the matching Shabad will open and follow your Pangtis.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom status bar

    /// Always visible, subtle, non-displacing. Reflects `audioState`
    /// + bufferEnergy but does NOT control the shabad content above.
    private var bottomStatusBar: some View {
        HStack(spacing: 12) {
            // Tiny waveform (compressed height — 36 pt vs 80 pt in
            // LiveResultsScreen). Animates with rms input.
            WaveformView(amplitude: engine.bufferEnergy, isActive: isRecording)
                .frame(maxWidth: 140, maxHeight: 36)
                .scaleEffect(y: 0.45, anchor: .center)
            statusLabel
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4))
        .animation(.easeInOut(duration: 0.2), value: engine.audioState)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch engine.audioState {
        case .idle:
            EmptyView()
        case .listening:
            Text("ਸੁਣ ਰਿਹਾ ਹਾਂ")
                .font(.notoSerifGurmukhi(13))
                .foregroundColor(Theme.onSurfaceVariant)
        case .recording:
            Text("ਰਿਕਾਰਡ")
                .font(.notoSerifGurmukhi(13, weight: .medium))
                .foregroundColor(Theme.primary)
        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.onSurfaceVariant)
                Text("ਖੋਜ ਰਿਹਾ ਹਾਂ")
                    .font(.notoSerifGurmukhi(13))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
        case .error(let msg):
            Text("ਮੁੜ ਕੋਸ਼ਿਸ਼ ਕਰ ਰਹੇ — \(String(msg.prefix(30)))")
                .font(.system(size: 11))
                .foregroundColor(Theme.warning)
                .lineLimit(1)
        }
    }

    private var isRecording: Bool {
        if case .recording = engine.audioState { return true }
        return false
    }
}
