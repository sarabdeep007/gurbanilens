import SwiftUI
import GurbaniLensCore
import AVFoundation

/// Minimal end-to-end smoke test for the audio + ASR + matcher pipeline.
///
/// Tap "Listen" → mic captures → whisper.cpp transcribes → Latin normalises →
/// matcher finds nearest SGGS Pangti → screen updates with current best
/// match, confidence, and a rolling transcript log.
///
/// No UI polish. Each row of data is shown plainly. Phase 2A step 5 builds
/// the real Follow View on top of this verified core.
struct SmokeTestView: View {

    @StateObject private var vm = SmokeTestViewModel()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                statusSection
                Divider()
                latestMatchSection
                Divider()
                logSection
                Spacer()
                listenButton
            }
            .padding()
            .navigationTitle("GurbaniLens Smoke Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    @ViewBuilder private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            Text(vm.statusText).font(.callout.monospaced())
            if let err = vm.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var latestMatchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Best match").font(.caption).foregroundStyle(.secondary)
            if let m = vm.latestMatch {
                HStack {
                    Text("Ang \(m.line.ang):P\(m.line.pangti ?? -1)").bold()
                    Text("[\(m.line.lineType ?? "-")]")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "conf %.1f", m.score))
                        .font(.callout.monospaced())
                        .foregroundStyle(m.score >= 75 ? .green : .orange)
                }
                if let unicode = m.line.gurmukhiUnicode {
                    Text(unicode)
                        .font(.title3)
                        .multilineTextAlignment(.leading)
                }
                if let translit = m.line.transliterationEn {
                    Text(translit).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("(waiting for confident match)").font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transcript log (most recent first)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.log.reversed(), id: \.id) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(String(format: "[%05.1fs]", row.time))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let s = row.matchScore {
                                    Text(String(format: "%.1f", s))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(s >= 75 ? .green : .orange)
                                }
                            }
                            Text(row.transcript).font(.callout)
                            Text(row.latin).font(.caption).foregroundStyle(.tertiary)
                            if let loc = row.matchLocation {
                                Text("→ \(loc)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(6)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    @ViewBuilder private var listenButton: some View {
        Button {
            vm.toggleListening()
        } label: {
            Text(vm.isListening ? "Stop" : "Listen")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(vm.isListening ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }
}

#Preview {
    SmokeTestView()
}
