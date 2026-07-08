import Foundation
import SwiftUI
import GurbaniLensCore

/// **Raagi Mode display contract.** Brief #9-iOS (2026-06-27).
///
/// Both engines that can drive the Raagi Mode UI — the existing
/// buffered ``RaagiModeEngine`` (Brief #8.x cascade) and the new
/// ``StreamingRaagiModeEngine`` (WebSocket-driven) — conform to this
/// protocol so ``RaagiModeScreen`` can render either one without
/// caring which is active. The user toggles between them via the
/// `settings.streamingModeEnabled` AppStorage key.
///
/// The protocol intentionally captures ONLY what the SwiftUI view
/// reads. `start()` / `stop()` lifecycle methods live on the concrete
/// engines and are driven by `AppContainer` — the screen doesn't see
/// them.
@MainActor
public protocol RaagiModeViewModel: ObservableObject {
    /// Sticky shabad on screen. `nil` → render the entry hint.
    var currentShabad: FullShabad? { get }
    /// SGGS Line.id of the highlighted pangti in the currently
    /// displayed shabad. `nil` iff `currentShabad` is `nil`.
    var currentLineId: String? { get }
    /// Mic / VAD / pipeline state — drives the bottom status bar.
    var audioState: RaagiAudioState { get }
    /// Live RMS for the waveform.
    var bufferEnergy: Float { get }
    /// Jaikara banner text (3-s auto-fade). `nil` between jaikaras.
    var activeJaikara: String? { get }
    /// Brief #9.26: progressive-narrowing candidate cloud state.
    /// `nil` (default) means no cloud shown. Only the streaming
    /// engine populates this — the buffered engine's extension
    /// returns nil unconditionally.
    var candidateCloud: CandidateCloudState? { get }
}

// Existing engine satisfies the protocol unchanged. Brief #9.26:
// buffered mode never surfaces the candidate cloud.
extension RaagiModeEngine: RaagiModeViewModel {
    public var candidateCloud: CandidateCloudState? { nil }
}

/// Brief #9.26: state for the progressive-narrowing candidate cloud
/// surfaced during uncertain sung-mode DISCOVERING. `.visible` means
/// the UI should render the cloud in place of the entry hint;
/// `.hidden` or `nil` means normal display (entry hint OR locked
/// shabad).
public enum CandidateCloudState: Equatable {
    case hidden
    case visible(rows: [SungModeAccumulatorStore.CandidateRow], partialsSeen: Int)
}
