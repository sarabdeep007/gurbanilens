import SwiftUI

/// Real-time audio waveform for the listening UI. Brief #7, 2026-06-25.
///
/// Internally maintains a fixed-size ring of recent amplitude samples
/// and renders them as vertical Capsule bars. The parent passes a
/// fresh `amplitude` value every time the audio pipeline updates it
/// (typically ~10 Hz from provider Partials carrying RMS); each new
/// value scrolls the ring left and appends. SwiftUI's implicit
/// animation on bar height keeps the motion smooth between the 10 Hz
/// data ticks.
///
/// Colour reflects state:
///   - `isActive = false` → subtle blue, low alpha. UI sits in
///     "Listening… (VAD waiting)" mode.
///   - `isActive = true`  → vivid saffron-like accent. UI is in
///     "Recording… (Silero detected speech)" mode.
struct WaveformView: View {

    /// Current amplitude 0..1 (RMS). Parent should hand this in from
    /// the session's `bufferEnergy` field every time it changes.
    let amplitude: Float
    /// `true` when VAD has detected speech (state `.recording`).
    /// Toggles the vivid accent colour.
    let isActive: Bool

    private static let barCount: Int = 40
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 4
    private static let totalHeight: CGFloat = 80
    private static let minBarHeight: CGFloat = 4
    /// Gain applied to RMS before mapping to bar height — RMS values
    /// for normal speech sit around 0.05–0.2, so we boost so that
    /// modest input produces a visible-but-not-clipping bar.
    private static let amplitudeGain: Float = 6.0

    @State private var samples: [Float] = Array(repeating: 0, count: WaveformView.barCount)

    var body: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(0..<samples.count, id: \.self) { i in
                Capsule()
                    .fill(barColor)
                    .frame(width: Self.barWidth, height: barHeight(for: samples[i]))
                    .animation(.easeOut(duration: 0.12), value: samples[i])
            }
        }
        .frame(height: Self.totalHeight)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Initialise the ring to current amplitude so a session
            // that opens mid-flow (e.g. after a fresh push) doesn't
            // briefly show flat-line.
            shiftAndAppend(amplitude)
        }
        .onChange(of: amplitude) { newValue in
            shiftAndAppend(newValue)
        }
    }

    private func shiftAndAppend(_ value: Float) {
        var next = samples
        next.removeFirst()
        next.append(value)
        samples = next
    }

    private var barColor: Color {
        if isActive {
            // Punjabi-saffron / app accent — chosen to be distinct
            // from the "listening" gray-blue.
            return Color(red: 1.0, green: 0.55, blue: 0.0)
        } else {
            return Color.blue.opacity(0.45)
        }
    }

    private func barHeight(for value: Float) -> CGFloat {
        let amplified = max(0, min(1, value * Self.amplitudeGain))
        let dynamic = CGFloat(amplified) * (Self.totalHeight - Self.minBarHeight)
        return Self.minBarHeight + dynamic
    }
}

#if DEBUG
struct WaveformView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            WaveformView(amplitude: 0.0, isActive: false)
            WaveformView(amplitude: 0.1, isActive: false)
            WaveformView(amplitude: 0.15, isActive: true)
            WaveformView(amplitude: 0.05, isActive: true)
        }
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
#endif
