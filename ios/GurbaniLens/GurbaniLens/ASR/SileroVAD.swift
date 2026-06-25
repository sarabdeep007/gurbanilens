import Foundation
import OnnxRuntimeBindings

/// Silero VAD v5 wrapper. Tiny LSTM-based voice-activity classifier
/// (1.8 MB ONNX) that returns a 0–1 speech probability per 512-sample
/// window @ 16 kHz (32 ms). The model is bundled under
/// `Resources/VAD/silero_vad.onnx`, fetched by
/// `scripts/fetch_ios_deps.sh`.
///
/// **Stateful**: maintains the LSTM hidden state across calls. Call
/// ``reset()`` at the start of each new mic session so a prior
/// session's accumulated state doesn't bias the first few windows.
///
/// **Not an actor by design.** The audio tap thread invokes
/// ``probability(samples:)`` synchronously from the AVAudioEngine
/// callback queue; an actor hop would block the tap. The ONNX runtime
/// session is thread-safe by Microsoft's documentation, and the LSTM
/// state buffer is updated under an NSLock so concurrent calls would
/// not corrupt it (though in practice only one tap-thread call is in
/// flight at a time).
///
/// **Failure mode**: any throw from ONNX returns 0.0 probability —
/// preferred over crashing the audio pipeline. The caller (CloudMic-
/// Capture) keeps a fallback energy-threshold path for sessions where
/// the model fails to load.
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
    public static let windowSamples: Int = 512        // 32 ms @ 16 kHz
    private static let stateShape: [NSNumber] = [2, 1, 128]
    private static let stateElementCount: Int = 2 * 1 * 128

    private let lock = NSLock()
    private let ortEnv: ORTEnv
    private let session: ORTSession
    private var lstmState: [Float]
    /// Resolved once at init so the `sr` ORTValue can be reused across
    /// every call (saves the ~50 µs of value construction per window).
    private let srTensor: ORTValue

    public init(modelPath: String) throws {
        // Validate model file exists; ONNX runtime errors out with an
        // opaque message otherwise and Deep would have to grep logs.
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw VADError.modelNotFound(path: modelPath)
        }

        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setLogSeverityLevel(.warning)
            self.ortEnv = env
            self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        } catch {
            throw VADError.sessionInitFailed(underlying: error)
        }

        self.lstmState = [Float](repeating: 0, count: Self.stateElementCount)

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

        NSLog("[DIAG] SileroVAD loaded model=\(modelPath) windowSamples=\(Self.windowSamples) sr=\(Self.sampleRate)")
    }

    /// Reset LSTM hidden state. Call at the start of each new mic
    /// session so prior speech context doesn't bias the first window's
    /// probability.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<lstmState.count { lstmState[i] = 0 }
    }

    /// Compute speech probability for `samples` (exactly
    /// ``windowSamples`` Float32 in [-1, 1]). Returns 0.0 on size
    /// mismatch or any internal failure — caller treats that as
    /// "silence" which is a safe default.
    public func probability(samples: [Float]) -> Float {
        guard samples.count == Self.windowSamples else { return 0 }

        lock.lock(); defer { lock.unlock() }

        do {
            // Input audio: [1, 512] float32.
            let inputData = samples.withUnsafeBufferPointer { ptr in
                NSMutableData(bytes: ptr.baseAddress, length: ptr.count * MemoryLayout<Float>.size)
            }
            let inputTensor = try ORTValue(
                tensorData: inputData,
                elementType: .float,
                shape: [1, NSNumber(value: Self.windowSamples)]
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
            if let stateOut = outputs["stateN"] {
                let stateBytes = try stateOut.tensorData() as Data
                if stateBytes.count == Self.stateElementCount * MemoryLayout<Float>.size {
                    stateBytes.withUnsafeBytes { raw in
                        guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
                        for i in 0..<Self.stateElementCount {
                            lstmState[i] = base[i]
                        }
                    }
                }
            }

            // Read probability scalar from output [1, 1].
            guard let outValue = outputs["output"] else { return 0 }
            let outBytes = try outValue.tensorData() as Data
            return outBytes.withUnsafeBytes { raw -> Float in
                guard let base = raw.bindMemory(to: Float.self).baseAddress,
                      raw.count >= MemoryLayout<Float>.size else { return 0 }
                return base[0]
            }
        } catch {
            NSLog("[DIAG] SileroVAD probability throw: \(error.localizedDescription)")
            return 0
        }
    }
}
