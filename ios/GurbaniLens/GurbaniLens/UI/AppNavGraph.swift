import SwiftUI
import GurbaniLensCore

/// v1 + v2 navigation. SwiftUI ``NavigationStack`` driven by ``Route``.
///
/// State machine:
///
///     Home ──tap (oneShot)──► Recording ──Done──► (Transcribing / Matching) ──► Results ──pick──► Shabad
///     Home ──tap (live)─────► LiveRecording ──Stop / VAD──► (Committing) ──► Results ──pick──► Shabad
///                                  │
///                                  └─ tap row ──────────────────► Shabad (skip Results)
///
/// Both `AppContainer` (nav path) and the nested `VoiceSearchSession`
/// must be observed at this level so that auto-advance (`.recording` /
/// `.liveRecording` → `.results` on `.done`) fires from the session's
/// state changes.
struct AppNavGraph: View {
    @ObservedObject var container: AppContainer
    @ObservedObject var session: VoiceSearchSession
    @AppStorage("settings.searchMode") private var searchModeRaw: String = SearchModeChoice.live.rawValue

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _session = ObservedObject(wrappedValue: container.session)
    }

    private var searchMode: SearchModeChoice {
        SearchModeChoice(rawValue: searchModeRaw) ?? .live
    }

    var body: some View {
        NavigationStack(path: $container.path) {
            HomeScreen(
                onSearchTap: {
                    if searchMode == .oneShot {
                        container.startRecording()
                    } else {
                        container.startLiveRecording()
                    }
                },
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
                case .liveRecording:
                    LiveResultsScreen(
                        session: session,
                        downloadProgress: container.modelDownloadProgress,
                        onStop: { container.commitLive() },
                        onCancel: { container.cancelLiveRecording() },
                        onCommit: { match in container.commitLive(match: match) }
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
    case recording        // v1 one-shot
    case liveRecording    // v2 search-as-you-speak
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
