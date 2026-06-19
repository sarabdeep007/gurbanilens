import SwiftUI
import GurbaniLensCore

/// v1 navigation. SwiftUI ``NavigationStack`` driven by ``Route``; Compose-
/// Android calls this an "AppNavGraph" so we keep the same name for parity.
///
/// State machine:
///
///     Home ──tap──► Recording ──stopSignal──► (Transcribing) ──asr done──► Results ──pick──► Shabad
///                       │                                                       │
///                       └── cancel ─────────────────────────────────────────► Home
///
/// Both ``AppContainer`` (nav path) and the nested ``VoiceSearchSession``
/// must be observed at this level so that auto-advance (`.recording` →
/// `.results` on `.done`) fires from the session's state changes.
struct AppNavGraph: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var session: VoiceSearchSession

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _session = ObservedObject(wrappedValue: container.session)
    }

    var body: some View {
        NavigationStack(path: $container.path) {
            HomeScreen(
                onSearchTap: { container.startRecording() },
                onSettingsTap: { container.path.append(Route.settings) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .recording:
                    RecordingScreen(
                        session: session,
                        livePreview: session.doneResult?.transcript ?? "",
                        onStop: { container.stopRecording() },
                        onCancel: { container.cancelRecording() }
                    )
                case .results:
                    ResultsScreen(
                        result: session.doneResult ?? .empty,
                        onBack: { container.returnHome() },
                        onTryAgain: { container.returnHome() },
                        onOpenShabad: { match in container.openShabad(for: match) }
                    )
                case .shabad(let payload):
                    ShabadScreen(
                        title: "Ang \(payload.lines.first?.ang ?? 0)",
                        lines: payload.lines,
                        focusLineId: payload.focusLineId,
                        onBack: { container.path.removeLast() }
                    )
                case .settings:
                    SettingsScreen(onBack: { container.path.removeLast() })
                }
            }
            .onChange(of: session.state) { _ in
                container.handleStateChange()
            }
            .alert("Error", isPresented: $container.showErrorAlert, actions: {
                Button("OK") { container.acknowledgeError() }
            }, message: {
                Text(session.errorMessage ?? "Something went wrong.")
            })
        }
        .preferredColorScheme(.dark)
    }
}

enum Route: Hashable {
    case recording
    case results
    case shabad(ShabadPayload)
    case settings
}

struct ShabadPayload: Hashable {
    let shabadId: String
    let focusLineId: String?
    let lines: [Line]

    func hash(into hasher: inout Hasher) {
        hasher.combine(shabadId)
        hasher.combine(focusLineId)
        // lines is large; hashing shabadId is enough — duplicates collapse correctly
    }

    static func == (lhs: ShabadPayload, rhs: ShabadPayload) -> Bool {
        lhs.shabadId == rhs.shabadId && lhs.focusLineId == rhs.focusLineId
    }
}
