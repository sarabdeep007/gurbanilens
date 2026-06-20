import SwiftUI

/// v1 Recording — pulsing mic, live VU bar, Cancel / Done. Mirrors
/// `android/.../ui/recording/RecordingScreen.kt`.
///
/// Live transcript preview (`livePreview`) is shown if the ASR pipeline emits
/// a partial transcript before the user taps Done. The one-shot ``Asr`` impl
/// does not produce partials — the field is left in for v1.1 when we add a
/// streaming pass with partial commits.
struct RecordingScreen: View {
    @ObservedObject var session: VoiceSearchSession
    let livePreview: String
    let onStop: () -> Void
    let onCancel: () -> Void

    private var statusLabel: String {
        switch session.state {
        case .recording:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .matching:     return "Searching…"
        case .error:        return "Error"
        default:            return ""
        }
    }

    private var peak: CGFloat {
        switch session.state {
        case .recording(let p): return CGFloat(p)
        case .transcribing:     return 1
        case .matching:         return 1
        default:                return 0
        }
    }

    /// Done is only meaningful while we're actively recording. Once the user
    /// taps it (session state → .transcribing), keep the button disabled so
    /// stray repeat-taps can't enqueue an empty-buffer run through
    /// runSearchAndDone — that path fires "No audio captured. Try again."
    /// even though the real capture is mid-transcribe.
    private var canTapDone: Bool {
        if case .recording = session.state { return true }
        return false
    }

    var body: some View {
        VStack {
            VStack(spacing: 32) {
                Spacer().frame(height: 64)
                Text(statusLabel)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Theme.primary)
                ZStack {
                    Circle().fill(Theme.primary)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundColor(Theme.onPrimary)
                }
                .frame(width: 180, height: 180)
                .scaleEffect(1.0 + peak * 0.4)
                .animation(.spring(response: 0.18, dampingFraction: 0.65), value: peak)

                if livePreview.isEmpty {
                    Text("Recite a Pangti aloud.")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.onSurfaceVariant)
                } else {
                    Text(livePreview)
                        .font(.system(size: 17, design: .monospaced))
                        .foregroundColor(Theme.onSurface)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            Spacer()
            HStack {
                Button(role: .cancel, action: onCancel) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark")
                        Text("Cancel")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Theme.surface, in: Capsule())
                    .foregroundColor(Theme.onSurface)
                }
                Spacer()
                Button(action: onStop) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                        Text("Done").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(canTapDone ? Theme.primary : Theme.surfaceVariant, in: Capsule())
                    .foregroundColor(canTapDone ? Theme.onPrimary : Theme.onSurfaceVariant)
                }
                .disabled(!canTapDone)
                .opacity(canTapDone ? 1 : 0.55)
                .animation(.easeOut(duration: 0.15), value: canTapDone)
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationBarBackButtonHidden(true)
    }
}
