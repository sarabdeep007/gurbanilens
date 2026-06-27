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

    @AppStorage("settings.raagiViewMode") private var viewModeRaw: String = "raagi"

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
        Group {
            if let shabad = engine.currentShabad, let lineId = engine.currentLineId {
                // Sticky shabad on screen. Audio cycles in the bottom
                // bar independently — this view doesn't react to
                // .listening / .recording / .processing transitions
                // at all.
                shabadView(shabad: shabad, lineId: lineId)
                    // .id() on the shabadId means SwiftUI treats a
                    // cross-shabad swap as "different view", which
                    // makes the .transition(.opacity) actually fire
                    // the cross-fade. Without the .id, SwiftUI sees
                    // the same RaagiView/SangatView struct and just
                    // updates props.
                    .id("\(shabad.id)#\(viewMode.rawValue)")
                    .transition(.opacity)
            } else {
                entryHint
                    .id("entry-hint")
                    .transition(.opacity)
            }
        }
        // .animation pulls SwiftUI into the .transition for both
        // (nil ↔ shabad) and (shabadA ↔ shabadB) swaps. 250 ms
        // matches the jaikara banner fade.
        .animation(.easeInOut(duration: 0.25), value: engine.currentShabad?.id)
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
