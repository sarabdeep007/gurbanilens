import Foundation
import GurbaniLensCore
import WhisperKit

/// On-device WhisperKit ASR backend conforming to ``ASRProvider``.
///
/// Wraps `WhisperKit.AudioStreamTranscriber` with Phase A.3's filter
/// stack (U+FFFD skip, hasDevanagari, "Waiting for speech…" blocklist,
/// repetition guard, low-energy + sustained-silence guard, warmup grace
/// for VAD-stop). All of that logic lived in `StreamingASR` through
/// Phase A.3; Phase A.4a moved it here so the StreamingASR facade can
/// pick a provider per `@AppStorage("settings.asrProvider")`.
///
/// **Model selection.** Caller passes a ``WhisperModel`` enum case;
/// default is `.medium` (~770 MB download). Phase 1 finding
/// established small drifts to Telugu on ambiguous Punjabi audio —
/// unacceptable for Whisper-only mode where there's no cloud
/// fallback. large-v3 scored 96.6 on Japji recitation but the 1.5 GB
/// initial pull is too heavy as a v1 default. medium is the right
/// balance: Punjabi-competent without the prohibitive download. Users
/// wanting maximum accuracy can select `.largeV3` from Settings →
/// Voice recognition → Local model. ``WhisperLiveTranscriber`` (used
/// by ``DualLiveProvider`` for word-by-word partials) stays hardcoded
/// at small — quality there is irrelevant because Sarvam refines at
/// VAD boundaries.
public actor WhisperKitProvider: ASRProvider {

    // MARK: - ASRProvider identity (nonisolated)

    public nonisolated let providerId: ASRProviderId = .whisperKit
    public nonisolated var displayName: String { "WhisperKit (\(model.shortDisplayName))" }
    public nonisolated var requiresNetwork: Bool { false }  // only on first model fetch

    // MARK: - Configuration

    private let model: WhisperModel
    private let language: String
    private let silenceThreshold: Float

    // MARK: - WhisperKit state

    private var pipe: WhisperKit?
    private var transcriber: AudioStreamTranscriber?
    private var decodeOptions: DecodingOptions?

    // MARK: - Streams

    private var currentStream: AsyncStream<Partial>?
    private var currentContinuation: AsyncStream<Partial>.Continuation?
    /// Latest active stream of partial transcripts. Empty (`finished`)
    /// before `start()` is first called and after `stop()`. Caller
    /// pattern: call `start()`, then iterate `await provider.partials`.
    public var partials: AsyncStream<Partial> {
        currentStream ?? AsyncStream { $0.finish() }
    }

    // MARK: - Model download progress (Phase A.4a — coarse-grained)
    //
    // WhisperKit ≥ 1.0 doesn't expose per-byte progress through its
    // public API; the closest is the `prewarm` / `load` knobs which
    // either block or don't. We emit `0.0` when init starts and `1.0`
    // when the pipe is loaded. A finer-grained progress hook is a
    // Phase B improvement once we audit WhisperKit's download path.
    private var downloadProgressContinuation: AsyncStream<Float>.Continuation?
    private let downloadProgressStream: AsyncStream<Float>
    public nonisolated let downloadProgress: AsyncStream<Float>
    /// Latches true once the WhisperKit pipe has loaded in the current
    /// session and 1.0 has been yielded; latches false at the top of
    /// every fresh `start()`. Gates ``yieldDownloadProgress`` so that
    /// stale polling-task hops already queued on the actor mailbox
    /// can't overwrite the final 1.0 with a 0.95 after the UI has
    /// already moved on (Deep's 2026-06-24 bug: progress bar stuck at
    /// 95 % even though pipe had loaded and Whisper was streaming).
    /// `pollingTask.cancel()` alone is insufficient — it sets the
    /// cancellation flag but doesn't unqueue actor messages already
    /// in flight from the polling task's `await self?.yield…` calls.
    private var loadComplete: Bool = false

    // MARK: - Filters & guards (Phase A.3 carry-over)

    private static let placeholderBlocklist: [String] = [
        "Waiting for speech",
        "<|"
    ]

    private var energyHistory: [Float] = []
    private var lastEmittedTextLength: Int = 0
    private let energyHistorySize: Int = 8
    private let lowEnergyThreshold: Float = 0.1

    private var streamStartTime: Date?
    private var maxEnergySeen: Float = 0
    private let warmupGracePeriod: TimeInterval = 1.5
    private let realAudioEnergyThreshold: Float = 0.1

    // MARK: - Init

    public init(
        model: WhisperModel = .medium,
        language: String = "pa",
        silenceThreshold: Float = 0.6
    ) {
        self.model = model
        self.language = (language == "pa") ? "hi" : language
        self.silenceThreshold = silenceThreshold

        // Set up the download-progress stream once at init so it can be
        // observed for the lifetime of the provider.
        let (dstream, dcont) = AsyncStream.makeStream(of: Float.self)
        self.downloadProgressStream = dstream
        self.downloadProgress = dstream
        self.downloadProgressContinuation = dcont

        if self.language != language {
            NSLog("[DIAG] WhisperKitProvider.init language remap \(language) → \(self.language) (small-model Punjabi workaround)")
        }
        NSLog("[DIAG] WhisperKitProvider.init model=\(model.rawValue) silenceThreshold=\(silenceThreshold)")
    }

    // MARK: - ASRProvider

    public func start() async throws {
        // Create a fresh stream every start so a stale `finished`
        // continuation from a previous `stop()` doesn't surface.
        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.currentStream = stream
        self.currentContinuation = cont
        // Reset the load-complete gate so this session's polling
        // task can emit until pipe loads.
        loadComplete = false

        // Build / reuse the WhisperKit pipe. Lookup order:
        //   1. Already-loaded pipe on this provider instance (same
        //      provider doing start → stop → start in one session).
        //   2. Process-wide WhisperKitPipeCache (different provider
        //      instance for the same model — AppContainer recreates
        //      StreamingASR + WhisperKitProvider between mic taps,
        //      so without this cache every tap re-validated and
        //      sometimes re-downloaded the ~770 MB medium model.
        //      Deep's 2026-06-24 bug report.)
        //   3. Fresh WhisperKit(config) load.
        let pipe: WhisperKit
        if let existing = self.pipe {
            pipe = existing
        } else if let cached = WhisperKitPipeCache.shared.cached(for: model.rawValue) {
            NSLog("[DIAG] WhisperKitProvider cache hit — reusing instance for model=\(model.rawValue)")
            pipe = cached
            self.pipe = cached
            downloadProgressContinuation?.yield(1.0)
        } else {
            downloadProgressContinuation?.yield(0.0)
            // Compute-unit selection — model-conditional. Deep's
            // 2026-06-24 iPhone test: large-v3's TextDecoder /
            // AudioEncoder MIL programs exceed Apple Neural Engine
            // capacity on consumer iPhones — the load fails with
            // "Program load failure (0x20004)" / "ANE model load has
            // failed" / "ANECF error" for ~6 minutes of retries before
            // giving up. Medium loaded fine on the same device, same
            // session. Fall back to CPU+GPU for large-v3 only — slower
            // per-inference but it actually loads. Smaller models keep
            // the ANE path because that's where they fit best.
            let compute: ModelComputeOptions
            if model == .largeV3 {
                NSLog("[DIAG] WhisperKitProvider.start large-v3 → using CPU+GPU compute (ANE incompatible at this model size on consumer iPhones)")
                compute = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                )
            } else {
                compute = ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
            }
            let config = WhisperKitConfig(
                model: model.rawValue,
                modelFolder: nil,
                computeOptions: compute,
                verbose: false,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: true
            )

            // File-size polling so the user sees a moving progress bar
            // instead of "0 %" for 10 minutes on a large-v3 cellular
            // download. The polling task runs detached, snapshots the
            // model directory's on-disk size every 500 ms, divides by
            // approximateBytes, caps at 0.95, and yields into the same
            // downloadProgressContinuation the UI subscribes to. Cap is
            // 0.95 so the bar doesn't sit at 100 % for a beat while
            // WhisperKit's CoreML compile + ANE-validation finishes;
            // the final 1.0 yield fires after `try await WhisperKit`
            // returns. Cancelled in both success and failure paths.
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let modelDir = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(model.rawValue)")
            let totalBytes = model.approximateBytes
            let pollingTask = Task.detached(priority: .background) { [weak self] in
                while !Task.isCancelled {
                    let size = WhisperKitProvider.directorySize(at: modelDir)
                    let progress = min(Float(0.95), Float(Double(size) / Double(totalBytes)))
                    await self?.yieldDownloadProgress(progress)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            NSLog("[DIAG] WhisperKitProvider.start loading \(model.rawValue) (this may download ~\(model.approximateSize) on first launch)")
            do {
                pipe = try await WhisperKit(config)
            } catch {
                pollingTask.cancel()
                // Corrupted-download detection. A partial / interrupted
                // model pull leaves CoreML files that fail to load with
                // messages like "Failed to parse ML Program", "Error in
                // reading the MIL network", or "...cannot be read". The
                // file is on disk so WhisperKit's auto-download skip
                // path then refuses to re-fetch. Purge the cached model
                // directory so the next start() pulls fresh.
                let msg = error.localizedDescription
                let looksCorrupted = msg.contains("Failed to parse ML Program")
                    || msg.contains("Error in reading the MIL network")
                    || msg.contains("cannot be read")
                // ANE-load failure detection (added 2026-06-24). Files
                // ARE valid on disk — the model is just too big or
                // shaped wrong for this device's Neural Engine. Don't
                // purge; surface a distinct error so the UI can suggest
                // a smaller model. With Fix 1 above large-v3 already
                // avoids the ANE path, but this catch covers
                // future-models-on-older-iPhones too.
                let aneLoadFailure = msg.contains("Program load failure")
                    || msg.contains("ANE model load has failed")
                    || msg.contains("ANECF error")
                    || msg.contains("0x20004")
                if looksCorrupted {
                    let removed: Bool
                    do {
                        try FileManager.default.removeItem(at: modelDir)
                        removed = true
                    } catch {
                        removed = false
                    }
                    NSLog("[DIAG] WhisperKitProvider corrupted model detected — purged=\(removed) path=\(modelDir.path), will redownload on next start")
                    throw WhisperKitProviderError.corruptedModelPurged
                } else if aneLoadFailure {
                    NSLog("[DIAG] WhisperKitProvider ANE load failure — model files valid on disk but Apple Neural Engine refused to load (likely too large for this device). err=\(msg.prefix(200))")
                    throw WhisperKitProviderError.aneIncompatible
                }
                throw error
            }
            pollingTask.cancel()
            // Latch BEFORE yielding 1.0. Any polling-task
            // `await self.yieldDownloadProgress(…)` already queued on
            // the actor mailbox will see loadComplete=true when it
            // finally runs and no-op, so the 1.0 stays sticky.
            loadComplete = true
            WhisperKitPipeCache.shared.store(pipe, for: model.rawValue)
            self.pipe = pipe
            downloadProgressContinuation?.yield(1.0)
            NSLog("[DIAG] WhisperKitProvider.start pipe loaded")
        }

        guard let tokenizer = pipe.tokenizer else {
            throw WhisperKitProviderError.missingTokenizer
        }

        // Build DecodingOptions once per provider instance.
        if self.decodeOptions == nil {
            self.decodeOptions = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: self.language,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                usePrefillPrompt: true,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                suppressBlank: true,
                compressionRatioThreshold: 2.0,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.45
            )
        }

        // Reset per-session guards.
        self.streamStartTime = Date()
        self.maxEnergySeen = 0
        self.energyHistory.removeAll(keepingCapacity: true)
        self.lastEmittedTextLength = 0

        let cb: AudioStreamTranscriberCallback = { [weak self] (old, new) in
            Task { await self?.handleStateChange(old: old, new: new) }
        }

        let t = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: self.decodeOptions!,
            requiredSegmentsForConfirmation: 2,
            silenceThreshold: silenceThreshold,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: cb
        )
        self.transcriber = t

        cont.onTermination = { @Sendable _ in
            Task { await self.stop() }
        }

        NSLog("[DIAG] WhisperKitProvider.start streaming begins language=\(self.language) silenceThreshold=\(silenceThreshold)")

        // Kick off the actual decode in a child Task so start() returns
        // promptly. Errors finish the stream cleanly.
        Task {
            do {
                try await t.startStreamTranscription()
            } catch {
                NSLog("[DIAG] WhisperKitProvider.startStreamTranscription threw: \(error.localizedDescription)")
                self.finishStream()
            }
        }
    }

    public func stop() async {
        guard let t = transcriber else { return }
        NSLog("[DIAG] WhisperKitProvider.stop()")
        Task { await t.stopStreamTranscription() }
        transcriber = nil
        currentContinuation?.finish()
        currentContinuation = nil
    }

    // MARK: - Internals

    public enum WhisperKitProviderError: LocalizedError {
        case missingTokenizer
        /// Raised after we've detected a partial / unparseable model
        /// on disk and purged the cache directory. The next `start()`
        /// call will pull the model fresh from huggingface.co.
        case corruptedModelPurged
        /// Raised when the model files are valid on disk but the Apple
        /// Neural Engine refuses to load them (typically because the
        /// model is too large for this device's ANE). Files are NOT
        /// purged — they're fine on a different compute path. UI
        /// should suggest picking a smaller model size.
        case aneIncompatible
        public var errorDescription: String? {
            switch self {
            case .missingTokenizer:
                return "WhisperKit pipe has no tokenizer loaded — model download / load may have failed."
            case .corruptedModelPurged:
                return "Voice model download was incomplete — cleared and ready to retry. Please tap Listen again."
            case .aneIncompatible:
                return "Voice model isn't compatible with this iPhone's Neural Engine. Tap Reset Whisper Models in Settings and try a smaller model size (Medium recommended)."
            }
        }
    }

    /// User-triggered reset (Settings → "Reset Whisper models"). Wipes
    /// the on-disk huggingface model cache AND the in-memory pipe
    /// cache, so the next `start()` reloads from scratch. Best-effort:
    /// directory-delete failures are logged but non-fatal — the
    /// in-memory cache clear always succeeds.
    public nonisolated static func resetAllModels() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
        do {
            try FileManager.default.removeItem(at: root)
            NSLog("[DIAG] WhisperKitProvider.resetAllModels purged on-disk cache at \(root.path)")
        } catch {
            NSLog("[DIAG] WhisperKitProvider.resetAllModels on-disk purge failed at \(root.path): \(error.localizedDescription)")
        }
        WhisperKitPipeCache.shared.clear()
    }

    /// Static helper exposed for unit tests + reuse downstream.
    public nonisolated static func hasDevanagari(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            scalar.value >= 0x0900 && scalar.value <= 0x097F
        }
    }

    private func handleStateChange(
        old: AudioStreamTranscriber.State,
        new: AudioStreamTranscriber.State
    ) {
        let currentText = new.currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Filter 1 — Bug C: U+FFFD mid-grapheme replacement char.
        if currentText.contains("\u{FFFD}") {
            NSLog("[DIAG] WhisperKitProvider skipping partial — U+FFFD in currentText (len=\(currentText.count))")
            return
        }

        // Filter 2 — Bug L / O: literal blocklist.
        for prefix in Self.placeholderBlocklist {
            if currentText.hasPrefix(prefix) {
                NSLog("[DIAG] WhisperKitProvider placeholder blocklist matched (prefix=\"\(prefix)\")")
                return
            }
        }

        // Filter 3 — Bug O: non-empty text must contain Devanagari.
        if !currentText.isEmpty && !Self.hasDevanagari(currentText) {
            NSLog("[DIAG] WhisperKitProvider placeholder filter suppressed non-Devanagari partial (head60=\"\(String(currentText.prefix(60)))\")")
            return
        }

        // Filter 4 — Bug G: repetition hallucination.
        if WhisperOneShot.isRepetitionHallucination(currentText) {
            NSLog("[DIAG] WhisperKitProvider suppressed repetition hallucination on partial (len=\(currentText.count))")
            return
        }

        // Filter 5 — Bug G: sustained low-energy + text growth.
        let energy = new.bufferEnergy.last ?? 0
        energyHistory.append(energy)
        if energyHistory.count > energyHistorySize {
            energyHistory.removeFirst()
        }
        if energy > maxEnergySeen { maxEnergySeen = energy }
        let sustainedLowEnergy = energyHistory.count >= energyHistorySize
            && energyHistory.allSatisfy { $0 < lowEnergyThreshold }
        let textGrew = currentText.count > lastEmittedTextLength
        if sustainedLowEnergy && textGrew {
            NSLog("[DIAG] WhisperKitProvider low-energy hallucination guard tripped — energy<\(lowEnergyThreshold) for \(energyHistorySize) partials, currentText grew \(lastEmittedTextLength)→\(currentText.count)")
            return
        }
        lastEmittedTextLength = currentText.count

        let latin = Latin.from(currentText)
        let gurmukhi = Gurmukhi.fromDevanagari(currentText)

        let partial = Partial(
            text: currentText,
            latin: latin,
            gurmukhi: gurmukhi,
            isSpeaking: new.isRecording,
            bufferEnergy: energy
        )

        NSLog("[DIAG] WhisperKitProvider partial isSpeaking=\(new.isRecording) text.len=\(currentText.count) latin.head60=\"\(String(latin.prefix(60)))\" gurmukhi.head60=\"\(String(gurmukhi.prefix(60)))\" energy=\(String(format: "%.3f", energy))")

        currentContinuation?.yield(partial)

        // Bug M: VAD-stop gate.
        if !new.isRecording && old.isRecording {
            let elapsed = streamStartTime.map { Date().timeIntervalSince($0) } ?? 0
            let realAudio = maxEnergySeen > realAudioEnergyThreshold
            if elapsed < warmupGracePeriod && !realAudio {
                NSLog("[DIAG] WhisperKitProvider VAD-stop SUPPRESSED (warmup or no-real-audio: elapsedMs=\(Int(elapsed * 1000)) maxEnergy=\(String(format: "%.3f", maxEnergySeen)))")
            } else {
                NSLog("[DIAG] WhisperKitProvider VAD-stop detected, finishing stream (elapsedMs=\(Int(elapsed * 1000)) maxEnergy=\(String(format: "%.3f", maxEnergySeen)))")
                finishStream()
            }
        }
    }

    private func finishStream() {
        currentContinuation?.finish()
        currentContinuation = nil
    }

    /// Actor-isolated yield onto the download-progress stream — called
    /// from the file-size polling Task during model fetch. The Task
    /// hops back into the actor via `await self?.yieldDownloadProgress`
    /// so writes to the continuation happen serialised against other
    /// actor work. The `loadComplete` gate drops late-arriving stale
    /// polling yields after the pipe has loaded and 1.0 has been
    /// emitted — without it, a 0.95 already queued on the actor
    /// mailbox at the moment of cancellation would overwrite the
    /// final 1.0, leaving the UI stuck at 95 %.
    fileprivate func yieldDownloadProgress(_ p: Float) {
        if loadComplete { return }
        downloadProgressContinuation?.yield(p)
    }

    /// Recursive on-disk byte count under `url`. Off-actor (`nonisolated
    /// static`) so the polling Task can call it without a hop. Returns 0
    /// when the directory doesn't exist yet or any error is hit — the
    /// caller treats 0 as 0% progress, which is correct for "download
    /// hasn't started writing files yet".
    public nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

/// Process-wide cache of loaded WhisperKit pipes keyed by model name.
/// Lives outside ``WhisperKitProvider`` so the pipe survives across
/// provider lifecycle — AppContainer clears `streamingAsr` after each
/// commit / returnHome / cancel, which would otherwise drop the pipe
/// and force WhisperKit to re-validate (and sometimes re-download)
/// the ~770 MB medium model on every mic tap (Deep's 2026-06-24
/// bug report). The cache holds at most one pipe per distinct model
/// rawValue; switching models in Settings doesn't evict the previous
/// one (rare action, not worth the eviction logic for v1).
final class WhisperKitPipeCache: @unchecked Sendable {
    static let shared = WhisperKitPipeCache()

    private let lock = NSLock()
    private var pipes: [String: WhisperKit] = [:]

    func cached(for modelName: String) -> WhisperKit? {
        lock.lock(); defer { lock.unlock() }
        return pipes[modelName]
    }

    func store(_ pipe: WhisperKit, for modelName: String) {
        lock.lock(); defer { lock.unlock() }
        pipes[modelName] = pipe
    }

    /// Drop every cached pipe. Pairs with on-disk model purge so the
    /// next start() loads fresh from disk (or re-downloads).
    func clear() {
        lock.lock()
        let count = pipes.count
        pipes.removeAll()
        lock.unlock()
        NSLog("[DIAG] WhisperKitPipeCache cleared (purged \(count) cached pipes)")
    }
}
