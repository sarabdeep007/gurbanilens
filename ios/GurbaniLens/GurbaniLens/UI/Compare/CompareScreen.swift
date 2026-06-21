import SwiftUI
import GurbaniLensCore

/// Phase A.4b debug screen — record one clip, fan it out to all three
/// ASR backends (WhisperKit large-v3 + Sarvam Saaras-v3 + Gemini 2.5
/// Flash) in parallel, render the transcripts side-by-side with per-
/// provider elapsed time. The deciding tool for Deep to pick which
/// cloud provider to commit to.
///
/// Hidden behind a 5-tap unlock on the Settings → Version footer
/// (settings.debugCompareEnabled). Production users never see this.
///
/// Flow:
///   1. Tap Record → MicSource starts (Float32, 16 kHz mono).
///   2. Up to 10 sec auto-stop, OR user taps Stop sooner.
///   3. The captured PCM is run through all three providers in parallel:
///      - WhisperKit via the existing WhisperOneShot path (one-shot)
///      - Sarvam via the REST batch endpoint (`/speech-to-text`)
///      - Gemini via the existing `transcribeOneShot` helper
///   4. As each provider returns, its row updates with elapsed-ms +
///      Gurmukhi transcript + Latin transliteration.
///   5. Save Comparison writes a JSON dump to Documents/compare-{ts}.json
///      so Deep can pull it via Xcode → Devices → Download Container.
struct CompareScreen: View {
    let onDismiss: () -> Void

    @StateObject private var session = CompareSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            transportRow
                .padding(.top, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.rows) { row in
                        ProviderResultRow(row: row)
                    }
                }
                .padding(.bottom, 12)
            }

            if let saveStatus = session.saveStatus {
                Text(saveStatus)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
            }

            HStack {
                Button("Save Comparison", action: { session.saveComparison() })
                    .disabled(!session.canSave)
                    .foregroundColor(session.canSave ? Theme.primary : Theme.onSurfaceVariant)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .themed()
        .navigationTitle("Compare ASR providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done", action: {
                    session.cancel()
                    onDismiss()
                })
            }
        }
        .onDisappear { session.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Record once, transcribe with all three.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            Text(session.statusText)
                .font(.system(size: 13))
                .foregroundColor(session.isRecording ? .red : Theme.onSurfaceVariant)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button(action: { session.toggleRecording() }) {
                HStack(spacing: 8) {
                    Image(systemName: session.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 28))
                    Text(session.isRecording ? "Stop" : "Record")
                        .font(.system(size: 17, weight: .semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .foregroundColor(session.isRecording ? .white : Theme.onPrimary)
                .background(session.isRecording ? Color.red : Theme.primary)
                .clipShape(Capsule())
            }
            Spacer()
            if let dur = session.captureDurationSec {
                Text(String(format: "%.1f s captured", dur))
                    .font(.system(size: 13))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
        }
    }
}

// MARK: - Provider result row

private struct ProviderResultRow: View {
    let row: CompareSession.ProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.onSurface)
                Spacer()
                Text(row.statusLabel)
                    .font(.system(size: 12))
                    .foregroundColor(row.status == .failed ? .red : Theme.onSurfaceVariant)
            }
            if row.gurmukhi.isEmpty {
                Text(row.placeholder)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.onSurfaceVariant)
            } else {
                Text(row.gurmukhi)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.onSurface)
                    .multilineTextAlignment(.leading)
                Text(row.latin)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Session state model

@MainActor
final class CompareSession: ObservableObject {

    enum RowStatus: String {
        case pending
        case running
        case done
        case failed
    }

    struct ProviderRow: Identifiable, Equatable {
        let id: ASRProviderId
        let title: String
        var status: RowStatus
        var elapsedMs: Int?
        var gurmukhi: String
        var latin: String
        var error: String?

        var statusLabel: String {
            switch status {
            case .pending: return "—"
            case .running: return "Transcribing…"
            case .done:    return elapsedMs.map { "\($0) ms" } ?? "done"
            case .failed:  return "Failed"
            }
        }

        var placeholder: String {
            switch status {
            case .pending: return "Tap Record + Stop to start."
            case .running: return "…"
            case .done:    return "(empty transcript)"
            case .failed:  return error ?? "Provider failed."
            }
        }
    }

    @Published var rows: [ProviderRow] = [
        ProviderRow(id: .whisperKit, title: "WhisperKit (large-v3)",
                    status: .pending, elapsedMs: nil, gurmukhi: "", latin: "", error: nil),
        ProviderRow(id: .sarvam, title: "Sarvam Saaras-v3",
                    status: .pending, elapsedMs: nil, gurmukhi: "", latin: "", error: nil),
        ProviderRow(id: .gemini, title: "Gemini 2.5 Flash",
                    status: .pending, elapsedMs: nil, gurmukhi: "", latin: "", error: nil),
    ]
    @Published var isRecording: Bool = false
    @Published var statusText: String = "Tap Record to start."
    @Published var captureDurationSec: Double?
    @Published var saveStatus: String?

    private let capture = RecordingCapture()
    private var capturedSamples: [Float] = []
    private var maxRecordTimer: Task<Void, Never>?
    private var compareTask: Task<Void, Never>?

    private static let maxRecordSeconds: Double = 10

    var canSave: Bool {
        rows.contains { $0.status == .done || $0.status == .failed }
    }

    // MARK: - Transport

    func toggleRecording() {
        if isRecording {
            stopAndCompare()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        resetRows()
        saveStatus = nil
        captureDurationSec = nil
        capturedSamples.removeAll(keepingCapacity: false)

        do {
            try capture.start()
            isRecording = true
            statusText = "Recording — up to 10 sec, or tap Stop."
            NSLog("[DIAG] CompareScreen recording started")
        } catch {
            statusText = "Mic start failed: \(error.localizedDescription)"
            NSLog("[DIAG] CompareScreen mic start FAILED: \(error.localizedDescription)")
            return
        }

        // Auto-stop after maxRecordSeconds.
        maxRecordTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxRecordSeconds * 1_000_000_000))
            await MainActor.run {
                if self?.isRecording == true {
                    self?.stopAndCompare()
                }
            }
        }
    }

    private func stopAndCompare() {
        guard isRecording else { return }
        maxRecordTimer?.cancel()
        maxRecordTimer = nil
        isRecording = false
        let samples = capture.stop()
        capturedSamples = samples
        captureDurationSec = Double(samples.count) / 16_000.0
        statusText = "Captured \(samples.count) samples — running providers in parallel…"
        NSLog("[DIAG] CompareScreen capture stopped samples=\(samples.count) sec=\(captureDurationSec ?? 0)")
        if samples.isEmpty {
            statusText = "No audio captured. Try again."
            return
        }
        compareTask?.cancel()
        compareTask = Task { [weak self] in
            await self?.runComparePass(samples: samples)
        }
    }

    func cancel() {
        maxRecordTimer?.cancel()
        maxRecordTimer = nil
        compareTask?.cancel()
        compareTask = nil
        if isRecording {
            capture.cancel()
            isRecording = false
        }
    }

    // MARK: - The parallel fan-out

    private func runComparePass(samples: [Float]) async {
        let pcmS16LE = Self.float32ToS16LE(samples)
        let wav = WavBuilder.wavFromS16LE(pcm: pcmS16LE)

        let sarvamKey = Bundle.main.object(forInfoDictionaryKey: "SARVAM_API_KEY") as? String ?? ""
        let geminiKey = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""

        // Start all three independently so a slow one doesn't block the
        // others. Each branch updates its row as soon as it lands.
        async let _wk: Void = runWhisperKit(samples: samples)
        async let _sv: Void = runSarvam(wav: wav, apiKey: sarvamKey)
        async let _gm: Void = runGemini(wav: wav, apiKey: geminiKey)
        _ = await (_wk, _sv, _gm)

        await MainActor.run {
            self.statusText = "Done. Save the comparison to keep results."
        }
    }

    private func runWhisperKit(samples: [Float]) async {
        await setRowStatus(.whisperKit, status: .running)
        let start = Date()
        do {
            let asr = WhisperOneShot(modelName: "openai_whisper-large-v3", modelFolder: nil)
            let transcript = try await asr.transcribe(samples, config: .default)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            // WhisperOneShot already returns text in Latin (matcher form)
            // + gurmukhi (display form). Use both directly.
            let raw = transcript.text
            let latin = raw
            let gurmukhi = transcript.gurmukhi.isEmpty
                ? raw
                : transcript.gurmukhi
            NSLog("[DIAG] CompareScreen provider=whisperKit elapsedMs=\(elapsed) text.head100=\"\(String(gurmukhi.prefix(100)))\"")
            await setRowDone(.whisperKit, elapsedMs: elapsed, gurmukhi: gurmukhi, latin: latin)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[DIAG] CompareScreen provider=whisperKit FAILED elapsedMs=\(elapsed) err=\(error.localizedDescription)")
            await setRowFailed(.whisperKit, elapsedMs: elapsed, error: error.localizedDescription)
        }
    }

    private func runSarvam(wav: Data, apiKey: String) async {
        await setRowStatus(.sarvam, status: .running)
        if apiKey.isEmpty {
            await setRowFailed(.sarvam, elapsedMs: 0, error: "SARVAM_API_KEY missing — populate .env and rebuild.")
            return
        }
        let start = Date()
        do {
            let transcript = try await SarvamProvider.transcribeOneShot(wav: wav, apiKey: apiKey)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let partial = SarvamProvider.makePartial(raw: transcript, isSpeaking: false, bufferEnergy: 0)
            NSLog("[DIAG] CompareScreen provider=sarvam elapsedMs=\(elapsed) text.head100=\"\(String(partial.gurmukhi.prefix(100)))\"")
            await setRowDone(.sarvam, elapsedMs: elapsed, gurmukhi: partial.gurmukhi, latin: partial.latin)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[DIAG] CompareScreen provider=sarvam FAILED elapsedMs=\(elapsed) err=\(error.localizedDescription)")
            await setRowFailed(.sarvam, elapsedMs: elapsed, error: error.localizedDescription)
        }
    }

    private func runGemini(wav: Data, apiKey: String) async {
        await setRowStatus(.gemini, status: .running)
        if apiKey.isEmpty {
            await setRowFailed(.gemini, elapsedMs: 0, error: "GEMINI_API_KEY missing — populate .env and rebuild.")
            return
        }
        let start = Date()
        do {
            let text = try await GeminiProvider.transcribeOneShot(wav: wav, apiKey: apiKey)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            let partial = GeminiProvider.makePartial(text: text, isSpeaking: false, bufferEnergy: 0)
            NSLog("[DIAG] CompareScreen provider=gemini elapsedMs=\(elapsed) text.head100=\"\(String(partial.gurmukhi.prefix(100)))\"")
            await setRowDone(.gemini, elapsedMs: elapsed, gurmukhi: partial.gurmukhi, latin: partial.latin)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[DIAG] CompareScreen provider=gemini FAILED elapsedMs=\(elapsed) err=\(error.localizedDescription)")
            await setRowFailed(.gemini, elapsedMs: elapsed, error: error.localizedDescription)
        }
    }

    // MARK: - Save

    func saveComparison() {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "timestamp_ms": timestamp,
            "capture_seconds": captureDurationSec ?? 0,
            "rows": rows.map { row in
                [
                    "providerId": row.id.rawValue,
                    "title": row.title,
                    "status": row.status.rawValue,
                    "elapsedMs": row.elapsedMs as Any,
                    "gurmukhi": row.gurmukhi,
                    "latin": row.latin,
                    "error": row.error as Any,
                ]
            }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let url = docs.appendingPathComponent("compare-\(timestamp).json")
            try data.write(to: url, options: .atomic)
            saveStatus = "Saved to \(url.lastPathComponent)"
            NSLog("[DIAG] CompareScreen saved comparison to \(url.path)")
        } catch {
            saveStatus = "Save failed: \(error.localizedDescription)"
            NSLog("[DIAG] CompareScreen save FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Row mutations

    private func resetRows() {
        rows = rows.map {
            var r = $0
            r.status = .pending
            r.elapsedMs = nil
            r.gurmukhi = ""
            r.latin = ""
            r.error = nil
            return r
        }
    }

    private func setRowStatus(_ id: ASRProviderId, status: RowStatus) async {
        await MainActor.run {
            if let i = self.rows.firstIndex(where: { $0.id == id }) {
                self.rows[i].status = status
            }
        }
    }

    private func setRowDone(_ id: ASRProviderId, elapsedMs: Int, gurmukhi: String, latin: String) async {
        await MainActor.run {
            if let i = self.rows.firstIndex(where: { $0.id == id }) {
                self.rows[i].status = .done
                self.rows[i].elapsedMs = elapsedMs
                self.rows[i].gurmukhi = gurmukhi
                self.rows[i].latin = latin
                self.rows[i].error = nil
            }
        }
    }

    private func setRowFailed(_ id: ASRProviderId, elapsedMs: Int, error: String) async {
        await MainActor.run {
            if let i = self.rows.firstIndex(where: { $0.id == id }) {
                self.rows[i].status = .failed
                self.rows[i].elapsedMs = elapsedMs
                self.rows[i].error = error
            }
        }
    }

    // MARK: - Float32 → s16le

    static func float32ToS16LE(_ samples: [Float]) -> Data {
        var bytes = Data(count: samples.count * 2)
        bytes.withUnsafeMutableBytes { raw in
            guard let basePtr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<samples.count {
                var v = samples[i]
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                basePtr[i] = Int16(v * 32767.0).littleEndian
            }
        }
        return bytes
    }
}
