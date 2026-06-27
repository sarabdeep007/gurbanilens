import Foundation
import AVFoundation

/// Mic capture for cloud ASR providers (``SarvamProvider``,
/// ``GeminiProvider``). Streams 16 kHz mono PCM s16le `Data` chunks live
/// during capture via an ``AsyncStream``, so a WebSocket / chunked-HTTP
/// uploader can push audio to the server as it arrives.
///
/// Sibling to ``MicSource`` (Float32, bulk-convert-at-stop) — they share
/// the AVAudioEngine pattern but the cloud capture path needs incremental
/// emission and a different output sample format. Splitting them avoids
/// retrofitting incremental Int16 emission into MicSource's bulk model
/// which v1 depends on.
///
/// **Co-existence rule.** Cloud capture MUST NOT run while WhisperKit's
/// AudioProcessor is alive (Bug F class — two captures fight over the
/// AVAudioSession). ``StreamingASR`` enforces this by instantiating
/// exactly one provider per session; cloud providers own the
/// CloudMicCapture lifecycle for their session and stop it on
/// ``ASRProvider/stop()``.
///
/// **Output contract.** Each emitted `Data` chunk is interleaved s16le,
/// 16 kHz, mono — i.e. `chunk.count / 2` samples. Chunk cadence follows
/// the input tap (~85 ms at 16k / 1024-frame native buffers) but the
/// caller should NOT rely on a fixed chunk size; Sarvam's streaming
/// endpoint and Gemini's 2-sec buffer both treat boundaries as
/// implementation details.
public final class CloudMicCapture {

    // MARK: - Errors

    public enum CaptureError: LocalizedError {
        case sessionConfigurationFailed(underlying: Error)
        case engineStartFailed(underlying: Error)
        case converterInitFailed
        case permissionDenied
        case permissionRequested

        public var errorDescription: String? {
            switch self {
            case .sessionConfigurationFailed(let e):
                return "Couldn't configure the audio session for cloud ASR: \(e.localizedDescription)"
            case .engineStartFailed(let e):
                return "Couldn't start the audio engine for cloud ASR: \(e.localizedDescription)"
            case .converterInitFailed:
                return "Couldn't build the audio converter to 16 kHz s16le."
            case .permissionDenied:
                return "Microphone permission was denied. Enable it in iOS Settings → Privacy → Microphone → GurbaniLens."
            case .permissionRequested:
                return "Microphone permission requested — please allow and try again."
            }
        }
    }

    // MARK: - State

    private let engine = AVAudioEngine()
    private let outputSampleRate: Double = 16_000
    private let outputFormatF32: AVAudioFormat
    private var nativeFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private let stateLock = NSLock()
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var _isRunning: Bool = false
    private var notificationObservers: [NSObjectProtocol] = []

    /// Diagnostic-only counter for `handleTapBuffer` invocations. Process-
    /// wide static (across all CloudMicCapture instances within a run)
    /// — fine because we recreate the object per session anyway. Used by
    /// the [DIAG] logs to distinguish "tap fires once" vs "tap fires
    /// repeatedly but yields stop" vs "converter starves" failure modes.
    private static var tapCallCount: Int = 0

    /// Per-tap activity callback. Carries:
    ///   - `peak`: max absolute sample amplitude in this tap (0..1).
    ///     Legacy field; pre-VAD providers used `peak > 0.02` as a
    ///     rough speech check.
    ///   - `rms`: root-mean-square amplitude (0..1) — drives waveform
    ///     animation amplitude in the UI.
    ///   - `vadActive`: Silero VAD said speech was present in this
    ///     tap. Providers should map this onto Partial.isSpeaking
    ///     so VoiceSearchSession's state machine can transition from
    ///     `.listening` (VAD waiting) to `.recording` (capturing).
    ///
    /// Renamed from `onPeak` 2026-06-25 (Brief #7) so the addition of
    /// RMS + vadActive doesn't silently break compat — the old name
    /// no longer exists; callers must update.
    public var onActivity: ((_ peak: Float, _ rms: Float, _ vadActive: Bool) -> Void)?

    /// **Continuous-mode utterance callback** (Brief #8.2, 2026-06-27).
    /// Fires when Silero VAD has decided one utterance is complete —
    /// either a silence-trail (raagi finished the pangti) or a max-
    /// recording cap (raagi sang past the 7-sec limit). The `Data` is
    /// a snapshot of the s16le bytes for THIS utterance only; safe to
    /// take ownership of and pass to a transcribe Task. The Int is
    /// the per-session utterance index (1-based, monotonic).
    ///
    /// Unlike `start()`'s `AsyncStream<Data>`, the callback model means
    /// **the mic stays running across utterance boundaries**. After
    /// the snapshot is delivered, this capture instance resets the
    /// VAD LSTM context + clears the internal buffer + sets
    /// `hasSpeechStarted = false`, then immediately resumes listening
    /// for the next utterance's onset. No stop/restart gap.
    ///
    /// The callback is invoked from the AVAudioEngine tap thread (NOT
    /// main). Consumers MUST hop to their isolation domain themselves
    /// — typically `Task { @MainActor in ... }` or
    /// `Task { await actor.method(...) }`. Set this BEFORE calling
    /// ``startContinuous()`` — there is no internal lock around the
    /// read on the tap thread, so a later assignment races.
    public var onUtteranceComplete: ((_ utteranceData: Data, _ utteranceNumber: Int) -> Void)?

    // MARK: - Silero VAD integration (Brief #7, 2026-06-25)

    /// Speech probability threshold above which Silero considers the
    /// frame "voiced". snakers4/silero-vad README default is 0.5;
    /// Brief #7.1 (2026-06-26) lowers to 0.3 for diagnosis after Deep's
    /// iPhone test showed VAD never triggering. Tune back up once we
    /// know the probability distribution from the on-device test.
    public static let vadThreshold: Float = 0.3
    /// Trailing-silence window after which we auto-finish the stream.
    /// Brief #8.2 (2026-06-27): 1500 → 500 ms. Deep's iPhone test
    /// showed actual between-pangti pauses in live kirtan are 300–
    /// 800 ms (breath catches, brief musical fills). 1500 ms never
    /// fired during continuous recitation, so the buffer grew until
    /// the max-recording hard cap cut a 15-sec multi-pangti blob —
    /// which IndicConformer transcribed as one continuous string
    /// the matcher couldn't pin to any single pangti.
    public static let silenceTrailMs: Double = 500
    /// Minimum cumulative speech duration before silence-trail auto-stop
    /// is allowed — prevents a 100 ms VAD blip on startup from auto-
    /// stopping immediately.
    public static let minSpeechMs: Double = 250
    /// Hard cap: regardless of VAD state, finish the stream this far
    /// in. Keeps a stuck-VAD recording from running forever. Brief
    /// #8.2 (2026-06-27): 15 → 7 sec. A typical pangti is 3–5 sec
    /// sung; 7 sec is a generous safety cap for the long ones. In
    /// continuous mode the cap just ends the current utterance and
    /// starts the next one — no audio is lost across the boundary.
    public static let maxRecordingMs: Double = 7_000
    /// Pre-speech ring buffer size. When VAD detects speech we flush
    /// the last ~1 s of buffered audio to the consumer so ASR sees
    /// the lead-in word's onset (otherwise the first ~80 ms of the
    /// utterance is lost while VAD was deciding).
    private static let preSpeechRingMaxBytes: Int = 32_000  // 1 s @ 16 kHz s16le

    private var silero: SileroVAD?
    private var sileroLoadAttempted: Bool = false

    /// Buffer of resampled 16 kHz Float32 samples awaiting a complete
    /// 512-sample VAD window. Drained per-tap.
    private var vadWindowBuffer: [Float] = []
    /// Did VAD detect speech in the current session? Once true, audio
    /// flows through to the consumer (after the pre-speech ring flush).
    private var hasSpeechStarted: Bool = false
    /// Pre-speech audio buffered while VAD waits for the first
    /// detection. Flushed on transition to speech.
    private var preSpeechRing = Data()
    /// Sample-accurate counters since speech start, for silence-trail
    /// and max-recording auto-stop.
    private var speechSampleCount: Int = 0
    private var silenceSampleCount: Int = 0
    private var totalSampleCount: Int = 0  // since speech started
    private var autoFinishFired: Bool = false

    // ── Continuous mode (Brief #8.2) ──────────────────────────────
    /// True when this capture session was started via
    /// ``startContinuous()`` instead of ``start()``. Changes the
    /// utterance-end behaviour in `handleTapBuffer`: instead of
    /// finishing the chunk stream, snapshot the utterance bytes,
    /// invoke ``onUtteranceComplete``, reset VAD, and keep recording.
    private var continuousMode: Bool = false
    /// Bytes accumulated for the current utterance in continuous mode.
    /// Reset to empty at each utterance boundary. The pre-speech ring
    /// flushes into here on speech-start; subsequent in-speech chunks
    /// append directly. Snapshotted by-value (`Data` has value
    /// semantics) when delivered to ``onUtteranceComplete``.
    private var utteranceBuffer = Data()
    /// Monotonic 1-based utterance counter for the current continuous
    /// session. Reset on `startContinuous()`. Logged + passed to the
    /// callback so consumers can correlate logs.
    private var utteranceCounter: Int = 0
    /// Retained AsyncStream for continuous mode (Brief #8.2.1, fix
    /// for #8.2 regression). `startContinuous()` calls `start()`,
    /// which returns the chunk AsyncStream and installs an
    /// `onTermination` handler that calls `stop()` when the stream
    /// deallocates. In continuous mode we don't read the stream
    /// (utterances flow through `onUtteranceComplete` instead) — if
    /// we discard it with `_ = try start()`, ARC deallocates it
    /// immediately, the termination handler fires, and the mic
    /// stops back-to-back with start. Hold the stream here so it
    /// lives until `stop()`. Cleared in `stop()` so the same instance
    /// can re-enter continuous mode in a later session.
    private var continuousModeStream: AsyncStream<Data>?

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    public init() {
        // Intermediate float32 mono target; we then int-encode to s16le
        // for emission. AVAudioConverter handles the resample +
        // channel-mix portion; the Float→Int16 step is a tight loop
        // below that's not worth giving to AVAudioConverter (which
        // resists writing into a raw byte buffer).
        guard let f = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("CloudMicCapture: failed to build 16 kHz Float32 output format")
        }
        self.outputFormatF32 = f
    }

    // MARK: - Lifecycle

    /// Begin capture. Returns an `AsyncStream<Data>` that yields s16le PCM
    /// chunks until ``stop()`` is called (or the stream's iterator is
    /// dropped). Subsequent ``start()`` calls after a ``stop()`` produce a
    /// fresh stream.
    public func start() throws -> AsyncStream<Data> {
        stateLock.lock()
        if _isRunning {
            stateLock.unlock()
            // Idempotent-ish: if already running, hand back the same
            // continuation's stream. We don't have a way to recreate it
            // without dropping data, so we surface a synthetic empty
            // stream that finishes immediately. Callers shouldn't hit
            // this in practice — StreamingASR gates the lifecycle.
            NSLog("[DIAG] CloudMicCapture.start REENTRY — returning empty stream")
            return AsyncStream { $0.finish() }
        }
        stateLock.unlock()

        try configureSession()
        try requestPermissionIfNeeded()

        // Per-session VAD state reset.
        ensureSilero()
        silero?.reset()
        vadWindowBuffer.removeAll(keepingCapacity: true)
        hasSpeechStarted = false
        preSpeechRing.removeAll(keepingCapacity: true)
        speechSampleCount = 0
        silenceSampleCount = 0
        totalSampleCount = 0
        autoFinishFired = false

        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        stateLock.lock()
        self.chunkContinuation = cont
        stateLock.unlock()

        installTap()

        do {
            try engine.start()
        } catch {
            cont.finish()
            stateLock.lock()
            self.chunkContinuation = nil
            stateLock.unlock()
            throw CaptureError.engineStartFailed(underlying: error)
        }

        stateLock.lock()
        _isRunning = true
        stateLock.unlock()

        registerInterruptionObservers()

        cont.onTermination = { [weak self] _ in
            self?.stop()
        }

        NSLog("[DIAG] CloudMicCapture.start nativeSR=\(nativeFormat?.sampleRate ?? -1) → 16000 mono s16le mode=\(continuousMode ? "continuous" : "one_shot")")
        return stream
    }

    /// Begin **continuous capture** (Brief #8.2, 2026-06-27). Unlike
    /// ``start()``, the audio bytes are not yielded to a chunk stream
    /// — instead, the capture buffers s16le internally and invokes
    /// ``onUtteranceComplete`` once per VAD-detected utterance
    /// (silence-trail OR max-recording cap), then resets VAD + buffer
    /// and **keeps recording**. No stop/restart gap between
    /// utterances; the mic stays hot for the lifetime of the
    /// session.
    ///
    /// Used by ``RaagiModeEngine`` to follow continuous kirtan
    /// recitation. Callers MUST set ``onUtteranceComplete`` before
    /// invoking this method (the capture starts firing on the audio
    /// thread immediately).
    ///
    /// Requires Silero VAD to be loaded — without it, utterance
    /// boundaries can't be detected and continuous mode silently
    /// drops everything. Logs a warning + returns successfully if
    /// VAD failed to load; consumers should set audioState to a
    /// degraded mode in that case.
    ///
    /// `stop()` ends the continuous session. The same lifecycle
    /// path as one-shot mode applies.
    public func startContinuous() throws {
        continuousMode = true
        utteranceBuffer.removeAll(keepingCapacity: true)
        utteranceCounter = 0
        // `start()` returns an AsyncStream<Data> that won't yield in
        // continuous mode (we route through onUtteranceComplete
        // instead). We MUST retain the stream — its
        // `cont.onTermination` calls `stop()` when the stream
        // deallocates, so discarding the return value tears the
        // session down immediately (Brief #8.2.1 fix).
        continuousModeStream = try start()
        if silero == nil {
            NSLog("[DIAG] CloudMicCapture.startContinuous WARNING — Silero VAD not loaded. Continuous mode requires VAD to delimit utterances; no utterances will be delivered.")
        }
    }

    /// Best-effort one-shot Silero VAD load. On any failure we log
    /// and continue without VAD — providers fall back to the legacy
    /// peak-threshold for the isSpeaking signal, and there's no
    /// silence auto-stop. That's a worse UX but doesn't crash the
    /// app, which is the right safety mode for a v1 dependency.
    private func ensureSilero() {
        if sileroLoadAttempted { return }
        sileroLoadAttempted = true
        guard let url = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else {
            NSLog("[DIAG] CloudMicCapture Silero VAD model not bundled — falling back to peak-threshold (no silence auto-stop)")
            return
        }
        do {
            silero = try SileroVAD(modelPath: url.path)
            NSLog("[DIAG] CloudMicCapture Silero VAD loaded — VAD-gated capture + silence auto-stop active")
        } catch {
            NSLog("[DIAG] CloudMicCapture Silero VAD init failed: \(error.localizedDescription) — falling back to peak-threshold")
        }
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = _isRunning
        let cont = chunkContinuation
        chunkContinuation = nil
        _isRunning = false
        stateLock.unlock()

        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        unregisterObservers()
        cont?.finish()
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        // Reset continuous-mode state so the same instance can be
        // started in one-shot mode next time. We don't clear the
        // callback — the owner may have its own lifecycle for that.
        let wasContinuous = continuousMode
        let utterancesFinished = utteranceCounter
        continuousMode = false
        utteranceBuffer.removeAll(keepingCapacity: true)
        utteranceCounter = 0
        // Release the retained stream — onTermination has already
        // fired (we just finished its continuation above) so this
        // is just letting ARC reclaim the AsyncStream wrapper.
        continuousModeStream = nil
        if wasContinuous {
            NSLog("[DIAG] CloudMicCapture.stop (continuous mode; utterancesDelivered=\(utterancesFinished))")
        } else {
            NSLog("[DIAG] CloudMicCapture.stop")
        }
    }

    // MARK: - Audio session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setPreferredSampleRate(outputSampleRate)
            try session.setPreferredIOBufferDuration(0.020)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw CaptureError.sessionConfigurationFailed(underlying: error)
        }
    }

    private func requestPermissionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return
        case .denied:
            throw CaptureError.permissionDenied
        case .undetermined:
            // Same Bug R-equivalent strategy as MicSource: fire async
            // and throw — user grants then retries.
            session.requestRecordPermission { _ in /* result handled on next tap */ }
            throw CaptureError.permissionRequested
        @unknown default:
            throw CaptureError.permissionDenied
        }
    }

    // MARK: - Tap install + per-tap encode

    private func installTap() {
        let inputNode = engine.inputNode
        let nf = inputNode.outputFormat(forBus: 0)
        self.nativeFormat = nf

        guard let monoNative = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nf.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        self.converter = AVAudioConverter(from: monoNative, to: outputFormatF32)

        NSLog("[DIAG] CloudMicCapture.installTap native sampleRate=\(nf.sampleRate) channels=\(nf.channelCount)")

        let tapBufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: nf
        ) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer)
        }
    }

    private func handleTapBuffer(_ buf: AVAudioPCMBuffer) {
        Self.tapCallCount += 1
        let tapNum = Self.tapCallCount
        if tapNum <= 5 || tapNum % 50 == 0 {
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) fired frames=\(buf.frameLength)")
        }
        guard buf.format.commonFormat == .pcmFormatFloat32,
              let chanData = buf.floatChannelData,
              let nf = nativeFormat else {
            return
        }
        let nch = Int(buf.format.channelCount)
        let frames = Int(buf.frameLength)
        if frames == 0 { return }

        // Brief #7.1 (2026-06-26): peek at raw chanData[0] BEFORE
        // downmix on the first 3 taps. Deep's iPhone test showed
        // bufferEnergy=0.0 throughout — we need to know whether the
        // mic itself is delivering zero samples or something
        // downstream is zeroing them.
        if tapNum <= 3 {
            let raw0 = chanData[0]
            let n = min(5, frames)
            var rawSamples: [String] = []
            for i in 0..<n {
                rawSamples.append(String(format: "%.5f", raw0[i]))
            }
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) RAW chanData[0] nch=\(nch) frames=\(frames) first5=\(rawSamples.joined(separator: ","))")
        }

        // Downmix to mono + per-tap peak + per-tap NATIVE-RATE RMS.
        // Native-rate RMS is the most reliable signal source: it
        // doesn't depend on the AVAudioConverter producing valid
        // output, which is one of the suspects in the bufferEnergy=0
        // bug. We pass this RMS to the onActivity callback so the
        // waveform stays connected to actual mic input even if the
        // resampler is broken.
        var monoChunk = [Float](repeating: 0, count: frames)
        var peak: Float = 0
        var sumSqNative: Float = 0
        if nch == 1 {
            let chan = chanData[0]
            for i in 0..<frames {
                let v = chan[i]
                monoChunk[i] = v
                let a = abs(v); if a > peak { peak = a }
                sumSqNative += v * v
            }
        } else {
            let inv = 1.0 / Float(nch)
            for c in 0..<nch {
                let ch = chanData[c]
                for i in 0..<frames { monoChunk[i] += ch[i] }
            }
            for i in 0..<frames {
                monoChunk[i] *= inv
                let a = abs(monoChunk[i]); if a > peak { peak = a }
                sumSqNative += monoChunk[i] * monoChunk[i]
            }
        }
        let rmsNative = frames > 0 ? (sumSqNative / Float(frames)).squareRoot() : 0

        if tapNum <= 3 {
            let n = min(5, frames)
            var monoSamples: [String] = []
            for i in 0..<n { monoSamples.append(String(format: "%.5f", monoChunk[i])) }
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) MONO peak=\(String(format: "%.5f", peak)) rmsNative=\(String(format: "%.5f", rmsNative)) first5=\(monoSamples.joined(separator: ","))")
        }

        // Wrap the mono float chunk in a PCMBuffer for AVAudioConverter.
        guard let monoNative = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: nf.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let inBuf = AVAudioPCMBuffer(
            pcmFormat: monoNative,
            frameCapacity: AVAudioFrameCount(frames)
        ) else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        if let dst = inBuf.floatChannelData?[0] {
            monoChunk.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: frames)
                }
            }
        }

        // Resample to 16 kHz Float32. Output capacity scales by ratio.
        let ratio = outputFormatF32.sampleRate / nf.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormatF32,
            frameCapacity: outCap
        ), let converter = self.converter else { return }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        // CRITICAL: reset converter state before each call. Without this,
        // AVAudioConverter treats the `.endOfStream` from the previous
        // tap's input block as a permanent terminal state and produces
        // 0 output frames for every subsequent convert() — even with a
        // fresh input buffer. See hotfix-6 diagnostic (commit 6bc62ae).
        converter.reset()
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) early-return: converter error=\(error?.localizedDescription ?? "nil") status=\(status.rawValue)")
            }
            return
        }

        // Float32 → Int16 little-endian, in-place into a Data buffer.
        let outFrames = Int(outBuf.frameLength)
        if outFrames == 0 {
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) early-return: outFrames=0 (converter produced no output)")
            }
            return
        }
        guard let chan = outBuf.floatChannelData?[0] else { return }

        // --- VAD + RMS over the converted 16 kHz mono Float32 frame ---
        // Compute the resampled-stage RMS too (diagnostic only — the
        // callback uses rmsNative which is more reliable). If the
        // converter is producing zeros, rmsResampled will be 0 even
        // when rmsNative is healthy — that's our smoking gun.
        var sumSq: Float = 0
        var peakResampled: Float = 0
        for i in 0..<outFrames {
            let v = chan[i]
            sumSq += v * v
            let a = abs(v); if a > peakResampled { peakResampled = a }
        }
        let rmsResampled = outFrames > 0 ? (sumSq / Float(outFrames)).squareRoot() : 0

        if tapNum <= 3 {
            let n = min(5, outFrames)
            var resampledSamples: [String] = []
            for i in 0..<n { resampledSamples.append(String(format: "%.5f", chan[i])) }
            NSLog("[DIAG] CloudMicCapture tap #\(tapNum) RESAMPLED outFrames=\(outFrames) peak=\(String(format: "%.5f", peakResampled)) rmsResampled=\(String(format: "%.5f", rmsResampled)) first5=\(resampledSamples.joined(separator: ","))")
        }

        // Silero VAD over 512-sample windows. Accumulate output
        // samples; each complete window goes through Silero. The
        // chunk-level vadActive is "did ANY window in this chunk
        // detect speech".
        var chunkVADActive = false
        var chunkMaxProb: Float = 0
        var chunkWindowCount: Int = 0
        if let silero = silero {
            for i in 0..<outFrames {
                vadWindowBuffer.append(chan[i])
            }
            while vadWindowBuffer.count >= SileroVAD.windowSamples {
                let window = Array(vadWindowBuffer.prefix(SileroVAD.windowSamples))
                vadWindowBuffer.removeFirst(SileroVAD.windowSamples)
                let prob = silero.probability(samples: window)
                chunkWindowCount += 1
                if prob > chunkMaxProb { chunkMaxProb = prob }
                if prob >= Self.vadThreshold {
                    chunkVADActive = true
                }
            }
            // Log probabilities for the first 5 taps (high info), plus
            // a sparse stream after that so production sessions still
            // get sample data.
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) VAD windowsThisTap=\(chunkWindowCount) maxProb=\(String(format: "%.3f", chunkMaxProb)) threshold=\(String(format: "%.2f", Self.vadThreshold)) vadActive=\(chunkVADActive)")
            }
        } else {
            // Fallback path when VAD didn't load — use legacy peak
            // threshold so providers still get a meaningful isSpeaking.
            chunkVADActive = peak > 0.02
        }

        // Report peak + RMS (NATIVE-rate; more reliable than the
        // post-resample one) + vadActive on the activity callback.
        // Providers map vadActive onto Partial.isSpeaking and pass
        // rmsNative as Partial.bufferEnergy for the waveform.
        onActivity?(peak, rmsNative, chunkVADActive)

        // --- Build s16le bytes for the consumer (existing) ---
        var bytes = Data(count: outFrames * 2)
        bytes.withUnsafeMutableBytes { raw in
            guard let basePtr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<outFrames {
                var v = chan[i]
                if v > 1.0 { v = 1.0 } else if v < -1.0 { v = -1.0 }
                let s = Int16(v * 32767.0)
                basePtr[i] = s.littleEndian
            }
        }

        // --- Gating, pre-speech buffering, auto-stop ---
        stateLock.lock()
        let cont = chunkContinuation
        stateLock.unlock()

        if silero == nil {
            // No VAD model — keep legacy behaviour: forward every chunk
            // to the consumer, no auto-stop, no pre-speech buffering.
            if tapNum <= 5 || tapNum % 50 == 0 {
                NSLog("[DIAG] CloudMicCapture tap #\(tapNum) yielding bytes=\(bytes.count) hasConsumer=\(cont != nil) [no-VAD]")
            }
            cont?.yield(bytes)
            return
        }

        // VAD-gated path.
        let chunkSamples = outFrames
        let chunkMs = Double(chunkSamples) / 16.0  // 16 samples per ms @ 16 kHz

        if !hasSpeechStarted {
            // Still waiting for first speech. Buffer current chunk in
            // pre-speech ring; never forward yet.
            preSpeechRing.append(bytes)
            if preSpeechRing.count > Self.preSpeechRingMaxBytes {
                let drop = preSpeechRing.count - Self.preSpeechRingMaxBytes
                preSpeechRing.removeFirst(drop)
            }
            if chunkVADActive {
                // First speech detected → transition to speech-active
                // and flush the pre-speech ring (which already
                // contains this chunk's bytes from the append above)
                // either to the one-shot consumer or the continuous-
                // mode internal buffer.
                hasSpeechStarted = true
                speechSampleCount = chunkSamples
                silenceSampleCount = 0
                totalSampleCount = chunkSamples
                let flush = preSpeechRing
                preSpeechRing = Data()
                NSLog("[DIAG] CloudMicCapture VAD speech-start detected — flushing pre-speech ring bytes=\(flush.count) (includes this chunk's bytes=\(bytes.count)) mode=\(continuousMode ? "continuous" : "one_shot")")
                if continuousMode {
                    utteranceBuffer.append(flush)
                } else {
                    cont?.yield(flush)
                }
            }
            // !chunkVADActive: stay waiting; return without yielding.
            return
        }

        // hasSpeechStarted == true: route the chunk.
        if continuousMode {
            utteranceBuffer.append(bytes)
        } else {
            cont?.yield(bytes)
        }
        totalSampleCount += chunkSamples
        if chunkVADActive {
            speechSampleCount += chunkSamples
            silenceSampleCount = 0
        } else {
            silenceSampleCount += chunkSamples
        }

        let silenceMs = Double(silenceSampleCount) / 16.0
        let speechMs = Double(speechSampleCount) / 16.0
        let totalMs = Double(totalSampleCount) / 16.0

        // Auto-stop conditions:
        //   1. silence-trail >= SILENCE_TRAIL_MS AND we've had enough
        //      speech (MIN_SPEECH_MS) to be sure it wasn't a blip
        //   2. hard cap: totalMs >= MAX_RECORDING_MS
        let trailingSilenceStop =
            silenceMs >= Self.silenceTrailMs && speechMs >= Self.minSpeechMs
        let maxDurationStop = totalMs >= Self.maxRecordingMs

        guard trailingSilenceStop || maxDurationStop else { return }

        let reason = trailingSilenceStop ? "silence_trail" : "max_recording"

        if continuousMode {
            // Continuous mode: snapshot current utterance, deliver to
            // callback, reset VAD + buffers, and KEEP RECORDING. Mic
            // stays hot — no stop/restart gap.
            utteranceCounter += 1
            let snapshot = utteranceBuffer
            let snapshotSec = Double(snapshot.count) / (16_000.0 * 2.0)
            let utteranceNum = utteranceCounter
            NSLog("[DIAG] CloudMicCapture utterance #\(utteranceNum) snapshot bufferSec=\(String(format: "%.2f", snapshotSec)) bytes=\(snapshot.count) reason=\(reason) silenceMs=\(Int(silenceMs)) speechMs=\(Int(speechMs)) totalMs=\(Int(totalMs)) — continuing capture")

            // Reset utterance state. Mic + tap stay live.
            utteranceBuffer = Data()
            hasSpeechStarted = false
            speechSampleCount = 0
            silenceSampleCount = 0
            totalSampleCount = 0
            autoFinishFired = false
            preSpeechRing.removeAll(keepingCapacity: true)
            // Reset Silero LSTM + 64-sample context so utterance #N+1
            // starts from a clean VAD state. Without this the trailing
            // silence of utterance #N would bias the start of
            // utterance #N+1's probability stream.
            silero?.reset()
            NSLog("[DIAG] CloudMicCapture VAD reset (continuing capture, utterance #\(utteranceNum + 1) starting)")

            // Fire callback from the audio thread — consumer is
            // responsible for hopping to its isolation domain.
            onUtteranceComplete?(snapshot, utteranceNum)
            return
        }

        // One-shot mode: existing behaviour. Finish the chunk stream
        // exactly once and let the provider POST the buffered audio.
        if !autoFinishFired {
            autoFinishFired = true
            NSLog("[DIAG] CloudMicCapture VAD auto-finish (reason=\(reason) silenceMs=\(Int(silenceMs)) speechMs=\(Int(speechMs)) totalMs=\(Int(totalMs)))")
            stateLock.lock()
            let finishCont = chunkContinuation
            chunkContinuation = nil
            stateLock.unlock()
            finishCont?.finish()
        }
    }

    // MARK: - Interruption handling

    private func registerInterruptionObservers() {
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                self?.handleInterruption(note)
            }
        )
    }

    private func unregisterObservers() {
        let center = NotificationCenter.default
        notificationObservers.forEach(center.removeObserver(_:))
        notificationObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            engine.pause()
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                try? engine.start()
            }
        @unknown default:
            break
        }
    }

    deinit {
        unregisterObservers()
    }
}

// MARK: - WAV builder (used by CompareScreen + GeminiProvider chunking)

public enum WavBuilder {
    /// Wrap a raw s16le mono `Data` buffer in a 44-byte WAV header so it
    /// can be sent as `audio/wav` to providers that won't accept raw PCM
    /// (Gemini). Sample rate hard-coded to match ``CloudMicCapture``'s
    /// emission (16 kHz, mono).
    public static func wavFromS16LE(pcm: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        func append(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(chunkSize))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                  // fmt chunk size
        append(UInt16(1))                   // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(blockAlign))
        append(UInt16(16))                  // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        var out = Data(capacity: 44 + dataSize)
        out.append(header)
        out.append(pcm)
        return out
    }
}
