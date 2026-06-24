import Foundation
import GurbaniLensCore
import WhisperKit

/// Live-loop WhisperKit transcriber for ``DualLiveProvider``. Consumes
/// the same 16 kHz s16le mono PCM that ``CloudMicCapture`` produces,
/// maintains a rolling Float32 buffer, and re-transcribes the buffer
/// every `refreshInterval` seconds via `pipe.transcribe(audioArray:)`
/// — the same WhisperKit public API ``WhisperOneShot`` already uses.
///
/// **Why not AudioStreamTranscriber.** WhisperKit's built-in streaming
/// transcriber owns its own AVAudioSession capture, which would
/// conflict with ``CloudMicCapture`` in dual-provider mode (iOS only
/// permits one capture session). Driving the transcribe API manually
/// with externally-supplied PCM is the only way both providers can
/// share the same mic.
///
/// **Why small, why rolling, why ~1s.** Latency is the dominant UX
/// signal for live word-by-word. Whisper-small transcribe is ~150–500
/// ms on a recent iPhone for a 1–3 second buffer; large-v3 is multiple
/// seconds and would defeat the purpose. The buffer is capped at
/// `maxBufferSec` (5 s by default) so transcribes don't grow
/// unboundedly — at ~3 s of speech Whisper is already producing useful
/// partials; longer windows mostly slow things down for diminishing
/// quality returns. Sarvam handles the high-quality refinement.
public actor WhisperLiveTranscriber {

    // MARK: - Config

    /// WhisperKit model id. Hardcoded to small for live cadence; see kdoc.
    public static let modelName = "openai_whisper-small"

    /// Re-run transcribe at most this often. Lower = more partials =
    /// higher CPU. Empirically ~600–800 ms gives a smooth feel on iPhone
    /// without monopolising the CPU.
    private let refreshInterval: TimeInterval

    /// Rolling buffer cap. Beyond this we drop oldest samples so each
    /// transcribe stays bounded.
    private let maxBufferSec: Double

    /// Below this number of samples in the buffer we skip the transcribe
    /// (not enough signal to be meaningful). 0.3 s @ 16 kHz = 4800.
    private let minSamplesToTranscribe: Int = 4800

    /// Decoding settings — copied from ``WhisperOneShot`` so behaviour
    /// matches. `pa` → `hi` remap inside transcribe() per the same
    /// small-model Punjabi workaround.
    private let language: String

    // MARK: - State

    private var pipe: WhisperKit?
    private let buffer = WhisperFloat32Buffer()
    private var consumerTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

    public init(
        language: String = "pa",
        refreshInterval: TimeInterval = 0.8,
        maxBufferSec: Double = 5.0
    ) {
        self.language = language
        self.refreshInterval = refreshInterval
        self.maxBufferSec = maxBufferSec
        NSLog("[DIAG] WhisperLiveTranscriber.init model=\(Self.modelName) refreshInterval=\(refreshInterval)s maxBufferSec=\(maxBufferSec)s")
    }

    // MARK: - Lifecycle

    /// Start the transcribe loop, consuming s16le mono 16 kHz chunks
    /// from `audioStream`. Returns immediately once the WhisperKit pipe
    /// is loaded (first call may take seconds for model download +
    /// CoreML compile). Subsequent calls reuse the loaded pipe.
    public func start(audioStream: AsyncStream<Data>) async throws {
        // Instance + model trace so concurrent / duplicate-construction
        // scenarios can be spotted in the logs. If two of these IDs
        // show up in one session, something's instantiating multiple
        // live transcribers behind our back (which would explain CPU
        // starvation + the 14 000 ms transcribeMs Deep saw).
        NSLog("[DIAG] WhisperLiveTranscriber.start instance=\(ObjectIdentifier(self).hashValue) modelName=\(Self.modelName)")
        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont
        await buffer.reset()

        // Ensure pipe.
        if pipe == nil {
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
            let config = WhisperKitConfig(
                model: Self.modelName,
                modelFolder: nil,
                computeOptions: compute,
                verbose: false,
                logLevel: .info,
                prewarm: true,
                load: true,
                download: true
            )
            NSLog("[DIAG] WhisperLiveTranscriber loading pipe (\(Self.modelName))")
            pipe = try await WhisperKit(config)
            NSLog("[DIAG] WhisperLiveTranscriber pipe loaded")
        }

        // Consume audio chunks off-actor — append to buffer without
        // hopping the actor for each chunk (same pattern as hotfix-5).
        let bufferRef = buffer
        let maxSamples = Int(maxBufferSec * 16_000)
        consumerTask = Task.detached(priority: .userInitiated) {
            for await chunk in audioStream {
                await bufferRef.append(chunk, maxSamples: maxSamples)
            }
        }

        // Transcribe loop — runs until stop() finishes the partials
        // continuation OR the consumer task drains naturally.
        transcribeTask = Task { [weak self] in
            await self?.runTranscribeLoop()
        }
    }

    public func stop() async {
        NSLog("[DIAG] WhisperLiveTranscriber.stop()")
        consumerTask?.cancel()
        transcribeTask?.cancel()
        consumerTask = nil
        transcribeTask = nil
        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Internals

    private func runTranscribeLoop() async {
        guard let pipe = pipe else { return }
        var loopCount = 0
        let effectiveLanguage: String = (language == "pa") ? "hi" : language

        while !Task.isCancelled {
            // Sleep refreshInterval; let stop()/cancel break out.
            try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
            if Task.isCancelled { break }

            let samples = await buffer.snapshot()
            if samples.count < minSamplesToTranscribe { continue }

            loopCount += 1
            let decode = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: effectiveLanguage,
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
            let start = Date()
            let results: [TranscriptionResult]
            do {
                results = try await pipe.transcribe(
                    audioArray: samples,
                    decodeOptions: decode
                )
            } catch {
                NSLog("[DIAG] WhisperLiveTranscriber transcribe FAILED loop=\(loopCount) bufferSec=\(String(format: "%.2f", Double(samples.count)/16_000)) err=\(error.localizedDescription)")
                continue
            }
            let transcribeMs = Int(Date().timeIntervalSince(start) * 1000)
            let combined = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Hallucination guard — same heuristic WhisperOneShot uses.
            if WhisperOneShot.isRepetitionHallucination(combined) {
                NSLog("[DIAG] WhisperLiveTranscriber suppressed repetition hallucination (len=\(combined.count))")
                continue
            }

            let latin = Latin.from(combined)
            let gurmukhi = Gurmukhi.fromDevanagari(combined)

            NSLog("[DIAG] WhisperLiveTranscriber chunk #\(loopCount) bufferSec=\(String(format: "%.2f", Double(samples.count)/16_000)) transcribeMs=\(transcribeMs) partialLen=\(combined.count) gurmukhi.head40=\"\(String(gurmukhi.prefix(40)))\"")
            if transcribeMs > 3000 {
                // 3 s for a 1–5 s small-model transcribe is at least
                // an order of magnitude past expected. Most likely
                // culprits: (a) another WhisperKit pipe instance is
                // active and the CPU/ANE is contended, (b) a partial
                // CoreML model load is mid-recovery, or (c) thermal
                // throttling. The instance log at start time pairs
                // with this one to identify (a).
                NSLog("[DIAG] WhisperLiveTranscriber SLOW PATH transcribeMs=\(transcribeMs) — possible CPU starvation or model conflict")
            }

            let partial = Partial(
                text: combined,
                latin: latin,
                gurmukhi: gurmukhi,
                isSpeaking: true,
                bufferEnergy: 0,  // energy comes from Sarvam path's
                                  // recordPeak in DualLiveProvider
                source: .whisperLive
            )
            partialsContinuation?.yield(partial)
        }
        NSLog("[DIAG] WhisperLiveTranscriber transcribe loop exit (cancelled or finished)")
    }
}

/// Lock-protected rolling Float32 buffer. Lives outside any actor so
/// the audio consumer can append without an actor hop per chunk (same
/// hotfix-5 lesson as `SarvamAudioBuffer`).
private actor WhisperFloat32Buffer {
    private var samples: [Float] = []

    func append(_ chunk: Data, maxSamples: Int) {
        // s16le → Float32 normalised to [-1, 1].
        let count = chunk.count / MemoryLayout<Int16>.size
        if count == 0 { return }
        var converted = [Float](repeating: 0, count: count)
        chunk.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<count {
                converted[i] = Float(Int16(littleEndian: base[i])) / 32768.0
            }
        }
        samples.append(contentsOf: converted)
        // Drop oldest if over cap — preserves the most recent
        // window so transcribe always sees current speech.
        if samples.count > maxSamples {
            let overflow = samples.count - maxSamples
            samples.removeFirst(overflow)
        }
    }

    func snapshot() -> [Float] {
        return samples
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
