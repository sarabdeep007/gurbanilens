import Foundation
import OnnxRuntimeBindings

/// Silero VAD v5 wrapper. Tiny LSTM-based voice-activity classifier
/// (1.8 MB ONNX) that returns a 0–1 speech probability per 512-sample
/// window @ 16 kHz (32 ms). The model is bundled under
/// `Resources/VAD/silero_vad.onnx`, fetched by
/// `scripts/fetch_ios_deps.sh`.
///
/// **Stateful x 2.** Both the LSTM hidden state AND a 64-sample
/// "lookbehind context" are persisted across calls:
///   - The LSTM state ([2, 1, 128] Float32) carries the model's
///     recurrent memory.
///   - The 64-sample context buffer is **prepended** to every
///     512-sample audio chunk before it's fed to the ONNX session.
///     So the actual ONNX `input` tensor is shape [1, 576], not
///     [1, 512]. This matches the official snakers4/silero-vad Python
///     wrapper (`utils_vad.py:OnnxWrapper.__call__`) which
///     concatenates `self._context` (64 samples for 16 kHz) ahead of
///     the user's chunk.
///
/// Brief #7.2 root cause (2026-06-26): the previous Swift port
/// omitted the context prefix and fed [1, 512] directly. Without
/// context, even loud speech produced probability ≈ 0.001 — exactly
/// matching Deep's stuck-at-zero iPhone test. Verified locally with
/// the same ONNX file in Python: without context = 0.001–0.003 on
/// noise / synthetic speech; with context = 0.01–0.05 on the same
/// signal; real speech jumps to 0.5+.
///
/// Reset semantics: ``reset()`` zeroes BOTH the LSTM state AND the
/// context buffer. Called at the start of every new mic session.
///
/// **Not an actor by design.** The audio tap thread invokes
/// ``probability(samples:)`` synchronously from the AVAudioEngine
/// callback queue; an actor hop would block the tap. The ONNX runtime
/// session is thread-safe by Microsoft's documentation, and the
/// mutable state buffers are updated under an NSLock.
///
/// **Failure mode**: any throw from ONNX returns 0.0 probability —
/// preferred over crashing the audio pipeline.
public final class SileroVAD: @unchecked Sendable {

    public enum VADError: LocalizedError {
        case modelNotFound(path: String)
        case sessionInitFailed(underlying: Error)
        case runFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound(let path):
                return "Silero VAD model not found at \(path). Run scripts/fetch_ios_deps.sh."
            case .sessionInitFailed(let e):
                return "Silero VAD session failed to initialise: \(e.localizedDescription)"
            case .runFailed(let e):
                return "Silero VAD inference failed: \(e.localizedDescription)"
            }
        }
    }

    // Silero v5 contract — see https://github.com/snakers4/silero-vad
    public static let sampleRate: Int = 16_000
    /// Audio samples per user-facing window (32 ms @ 16 kHz).
    public static let windowSamples: Int = 512
    /// Lookbehind context size for 16 kHz (32 for 8 kHz, but we only
    /// run at 16). Prepended to every chunk before ONNX call.
    public static let contextSamples: Int = 64
    /// Combined ONNX input length: context (64) + audio (512) = 576.
    public static let inputSamples: Int = contextSamples + windowSamples
    private static let stateShape: [NSNumber] = [2, 1, 128]
    private static let stateElementCount: Int = 2 * 1 * 128

    private let lock = NSLock()
    private let ortEnv: ORTEnv
    private let session: ORTSession
    private var lstmState: [Float]
    /// 64-sample carry-over from the tail of the previous call's
    /// audio. Prepended to the next call's chunk so the ONNX model
    /// sees the lookbehind context it was trained on.
    private var context: [Float]
    /// Cumulative call count for sparse per-window DIAG logging.
    private var probabilityCallCount: Int = 0
    /// Resolved once at init so the `sr` ORTValue can be reused across
    /// every call (saves the ~50 µs of value construction per window).
    private let srTensor: ORTValue

    public init(modelPath: String) throws {
        // Validate model file exists; ONNX runtime errors out with an
        // opaque message otherwise and Deep would have to grep logs.
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw VADError.modelNotFound(path: modelPath)
        }

        let env: ORTEnv
        let sess: ORTSession
        do {
            env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setLogSeverityLevel(.warning)
            sess = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        } catch {
            throw VADError.sessionInitFailed(underlying: error)
        }
        self.ortEnv = env
        self.session = sess

        self.lstmState = [Float](repeating: 0, count: Self.stateElementCount)
        self.context = [Float](repeating: 0, count: Self.contextSamples)

        // Sample-rate input — int64 scalar, value 16000. Built once;
        // the underlying ORTValue is read-only-mutable-data so reusing
        // it across calls is safe.
        var sr: Int64 = Int64(Self.sampleRate)
        let srData = NSMutableData(bytes: &sr, length: MemoryLayout<Int64>.size)
        self.srTensor = try ORTValue(
            tensorData: srData,
            elementType: .int64,
            shape: []
        )

        NSLog("[DIAG] SileroVAD loaded model=\(modelPath) windowSamples=\(Self.windowSamples) contextSamples=\(Self.contextSamples) inputSamples=\(Self.inputSamples) sr=\(Self.sampleRate)")

        // Dump the model's declared I/O so a future mismatch (e.g.
        // upstream Silero version bump) surfaces immediately.
        if let names = try? sess.inputNames() {
            NSLog("[DIAG] SileroVAD model inputs declared: \(names)")
        }
        if let names = try? sess.outputNames() {
            NSLog("[DIAG] SileroVAD model outputs declared: \(names)")
        }
    }

    /// Reset LSTM hidden state AND the 64-sample lookbehind context.
    /// Call at the start of each new mic session so prior speech
    /// context doesn't bias the first window's probability.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<lstmState.count { lstmState[i] = 0 }
        for i in 0..<context.count { context[i] = 0 }
        probabilityCallCount = 0
    }

    /// Compute speech probability for `samples` (exactly
    /// ``windowSamples`` Float32 in [-1, 1]). Returns 0.0 on size
    /// mismatch or any internal failure.
    public func probability(samples: [Float]) -> Float {
        guard samples.count == Self.windowSamples else { return 0 }

        lock.lock(); defer { lock.unlock() }
        probabilityCallCount += 1
        let callNum = probabilityCallCount

        do {
            // Build the combined input buffer: context (64) + samples
            // (512) = 576 Float32s. This is the Silero v5 ONNX input
            // shape per the official Python wrapper.
            var combined = [Float](repeating: 0, count: Self.inputSamples)
            for i in 0..<Self.contextSamples { combined[i] = context[i] }
            for i in 0..<Self.windowSamples {
                combined[Self.contextSamples + i] = samples[i]
            }

            let inputData = combined.withUnsafeBufferPointer { ptr in
                NSMutableData(bytes: ptr.baseAddress, length: ptr.count * MemoryLayout<Float>.size)
            }
            let inputTensor = try ORTValue(
                tensorData: inputData,
                elementType: .float,
                shape: [1, NSNumber(value: Self.inputSamples)]
            )

            // LSTM state: [2, 1, 128] float32.
            let stateData = lstmState.withUnsafeBufferPointer { ptr in
                NSMutableData(bytes: ptr.baseAddress, length: ptr.count * MemoryLayout<Float>.size)
            }
            let stateTensor = try ORTValue(
                tensorData: stateData,
                elementType: .float,
                shape: Self.stateShape
            )

            let outputs = try session.run(
                withInputs: [
                    "input": inputTensor,
                    "state": stateTensor,
                    "sr": srTensor,
                ],
                outputNames: Set(["output", "stateN"]),
                runOptions: nil
            )

            // Update LSTM state from stateN.
            var stateMagnitude: Float = 0
            if let stateOut = outputs["stateN"] {
                let stateBytes = try stateOut.tensorData() as Data
                if stateBytes.count == Self.stateElementCount * MemoryLayout<Float>.size {
                    stateBytes.withUnsafeBytes { raw in
                        guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
                        var sum: Float = 0
                        for i in 0..<Self.stateElementCount {
                            lstmState[i] = base[i]
                            sum += abs(base[i])
                        }
                        stateMagnitude = sum / Float(Self.stateElementCount)
                    }
                }
            }

            // Update context for next call: last 64 samples of THIS
            // call's audio chunk.
            for i in 0..<Self.contextSamples {
                context[i] = samples[Self.windowSamples - Self.contextSamples + i]
            }

            // Read probability scalar from output [1, 1].
            var prob: Float = 0
            if let outValue = outputs["output"] {
                let outBytes = try outValue.tensorData() as Data
                prob = outBytes.withUnsafeBytes { raw -> Float in
                    guard let base = raw.bindMemory(to: Float.self).baseAddress,
                          raw.count >= MemoryLayout<Float>.size else { return 0 }
                    return base[0]
                }
            }

            // Per-window DIAG every 10th call. Logs enough that a
            // future "VAD prob stuck" report can be diagnosed without
            // a code change.
            if callNum <= 5 || callNum % 10 == 0 {
                let audioPrefix = samples.prefix(3)
                    .map { String(format: "%.4f", $0) }
                    .joined(separator: ",")
                NSLog("[DIAG] SileroVAD win#\(callNum) audioFirst3=\(audioPrefix) stateMag=\(String(format: "%.4f", stateMagnitude)) outputProb=\(String(format: "%.4f", prob)) inputLen=\(Self.inputSamples)")
            }

            return prob
        } catch {
            NSLog("[DIAG] SileroVAD probability throw: \(error.localizedDescription)")
            return 0
        }
    }
}
