import Foundation
import SwiftUI
import AVFoundation
import GurbaniLensCore

@MainActor
final class SmokeTestViewModel: ObservableObject {

    struct LogRow: Identifiable {
        let id = UUID()
        let time: Double
        let transcript: String
        let latin: String
        let matchScore: Double?
        let matchLocation: String?
    }

    // Outputs
    @Published var isListening: Bool = false
    @Published var statusText: String = "Idle. Tap Listen to begin."
    @Published var lastError: String?
    @Published var latestMatch: Match?
    @Published private(set) var log: [LogRow] = []

    // Pipeline
    private var audio: AudioSource?
    private var asr: WhisperASR?
    private var matcher: Matcher?

    // MARK: - Lifecycle

    func toggleListening() {
        if isListening { stopListening() } else { Task { await startListening() } }
    }

    private func startListening() async {
        lastError = nil
        statusText = "Loading corpus + matcher…"
        do {
            let matcher = try Self.makeMatcher()
            self.matcher = matcher

            statusText = "Loading Whisper model…"
            let modelURL = try Self.findBundledModel()
            let cfg = WhisperASR.Config(modelPath: modelURL)
            let asr = try WhisperASR(config: cfg)
            self.asr = asr

            await asr.attach { [weak self] segment in
                Task { @MainActor [weak self] in
                    self?.handleSegment(segment)
                }
            }

            statusText = "Configuring audio session…"
            let mic = MicSource()
            self.audio = mic
            try mic.start { [weak self] buffer, time in
                guard let self else { return }
                Task { await self.asr?.feed(buffer, time: time) }
            }

            isListening = true
            statusText = "Listening — \(mic.configurationDescription)"
        } catch {
            lastError = error.localizedDescription
            statusText = "Idle (last attempt failed)."
            stopListening()
        }
    }

    private func stopListening() {
        audio?.stop()
        audio = nil
        Task { await asr?.stop() }
        isListening = false
        statusText = "Stopped."
    }

    // MARK: - Handlers

    private func handleSegment(_ seg: WhisperASR.ASRSegment) {
        guard let matcher = matcher else { return }
        let results = matcher.match(seg.textLatin, topN: 1)
        let top = results.first

        let location = top.map { "Ang \($0.line.ang):P\($0.line.pangti ?? -1)" }
        log.append(LogRow(
            time: seg.startTime,
            transcript: seg.text,
            latin: seg.textLatin,
            matchScore: top?.score,
            matchLocation: location
        ))
        if log.count > 100 { log.removeFirst(log.count - 100) }

        if let top, top.score >= 75 {
            latestMatch = top
        }
    }

    // MARK: - Helpers

    private static func makeMatcher() throws -> Matcher {
        guard let dbURL = Bundle.main.url(forResource: "app_database", withExtension: "sqlite") else {
            throw NSError(
                domain: "GurbaniLens", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "app_database.sqlite missing from app bundle. Run `cd build && npm run convert && python build_app_database.py` and re-bundle. See docs/PHASE_2A_IOS_SETUP.md."]
            )
        }
        let corpus = try Corpus(dbPath: dbURL)
        return try Matcher(corpus: corpus)
    }

    private static func findBundledModel() throws -> URL {
        // Look for the standard ggml model file (small is the Phase 2A default).
        for name in ["ggml-small", "ggml-base", "ggml-medium"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "bin") {
                return url
            }
        }
        throw NSError(
            domain: "GurbaniLens", code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "No Whisper model bundled. Run `bash build/fetch_whisper_models.sh` then add the .bin (and matching .mlmodelc) to Resources/Models. See docs/whisper_coreml_setup.md."]
        )
    }
}
