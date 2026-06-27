import SwiftUI
import GurbaniLensCore

/// Root container for Raagi Mode. Brief #8 Commit 6/7.
///
/// **Composition**:
///   - Top toolbar: X exit button (left), view-mode toggle (right)
///   - Center: state-conditional content
///       .idle / .listening / .recording (no shabad yet) → entry hint
///       .processing (no shabad yet)                     → entry hint
///       .displaying (shabad on screen)                  → RaagiView
///                                                          or
///                                                          SangatView
///                                                          per view
///                                                          toggle
///       .error                                          → small
///                                                          retry hint
///   - Bottom: per-tap waveform + status caption
///   - Overlay: JaikaraBanner (when engine.jaikaraBanner != nil)
///
/// **View toggle**: persisted via @AppStorage so re-entering Raagi
/// Mode remembers the user's choice. Default "raagi".
///
/// **Sticky display**: once a shabad is displayed, the RaagiView /
/// SangatView stays visible even while subsequent utterances go
/// through .recording / .processing. The bottom waveform + status
/// strip is what shows the live activity.
struct RaagiModeScreen: View {
    @ObservedObject var engine: RaagiModeEngine
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
                if let jaikara = engine.jaikaraBanner {
                    JaikaraBanner(text: jaikara)
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: engine.jaikaraBanner)
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .idle, .listening, .recording, .processing:
            // No shabad yet — entry hint.
            entryHint
        case .displaying(let shabad, let lineId):
            // Sticky display — the view stays on through subsequent
            // .recording / .processing transitions until a new match
            // arrives.
            switch viewMode {
            case .raagi:
                RaagiView(shabad: shabad, currentLineId: lineId)
            case .sangat:
                SangatView(shabad: shabad, currentLineId: lineId)
            }
        case .error(let msg):
            errorHint(msg)
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

    private func errorHint(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(Theme.warning)
            Text("Connection hiccup — retrying…")
                .font(.system(size: 16))
                .foregroundColor(Theme.onSurface)
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom status bar

    private var bottomStatusBar: some View {
        VStack(spacing: 6) {
            WaveformView(amplitude: engine.bufferEnergy, isActive: isRecording)
                .padding(.horizontal, 28)
            Text(statusCaption)
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4))
    }

    private var isRecording: Bool {
        if case .recording = engine.state { return true }
        return false
    }

    private var statusCaption: String {
        switch engine.state {
        case .idle:                       return "Stopped"
        case .listening:                  return "Listening…"
        case .recording:                  return "Recording…"
        case .processing:                 return "Searching…"
        case .displaying:                 return "Listening for next Pangti…"
        case .error:                      return "Retrying…"
        }
    }
}
