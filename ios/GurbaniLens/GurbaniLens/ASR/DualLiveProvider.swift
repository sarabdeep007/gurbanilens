import Foundation
import GurbaniLensCore

/// **Dual-provider live ASR.** Runs ``WhisperLiveTranscriber`` (small
/// model, sub-second rolling partials) and ``SarvamProvider``
/// (Saaras-v3 streaming via Starscream, VAD-segmented high-quality
/// Punjabi) in parallel against a single mic stream. Whisper's rolling
/// partials show first so the user sees text immediately; when each
/// Sarvam segment closes, Sarvam's higher-quality transcript replaces
/// the rolling Whisper text in the UI.
///
/// **Architecture.**
/// ```
///   CloudMicCapture ──► ChunkBroadcaster ──┬─► WhisperLiveTranscriber ─┐
///                                          │                            │
///                                          └─► SarvamProvider           ├─► partialsContinuation
///                                              (external stream mode)   │   (with source tag)
/// ```
/// Single AVAudioSession; both consumers see every chunk.
///
/// **UX merge rule.** Once Sarvam has emitted any segment, the dual
/// provider stops forwarding Whisper partials — Sarvam's accumulated
/// transcript is canonical from that point on. Whisper still keeps
/// running (cheap), but its outputs are dropped. This avoids the
/// ping-pong where late Whisper updates would overwrite a more recent
/// Sarvam emit. The first Sarvam emit may be shorter than the last
/// Whisper emit; VoiceSearchSession's freeze-last-good guard bypasses
/// the shrink check when `partial.source == .sarvam` so the
/// authoritative text wins.
public actor DualLiveProvider: ASRProvider {

    // MARK: - ASRProvider identity

    public nonisolated let providerId: ASRProviderId = .dual
    public nonisolated let displayName: String = "Dual (Whisper live + Sarvam refine)"
    public nonisolated let requiresNetwork: Bool = true

    // MARK: - Children

    private let capture: CloudMicCapture
    private var broadcaster: ChunkBroadcaster?
    private let whisper: WhisperLiveTranscriber
    private let sarvam: SarvamProvider

    // MARK: - Merge state

    private var sarvamHasSpoken: Bool = false
    private var whisperPartialCount: Int = 0
    private var sarvamSegmentCount: Int = 0
    private var whisperTask: Task<Void, Never>?
    private var sarvamTask: Task<Void, Never>?

    private var partialsContinuation: AsyncStream<Partial>.Continuation?
    private var partialsStream: AsyncStream<Partial>?
    public var partials: AsyncStream<Partial> {
        partialsStream ?? AsyncStream { $0.finish() }
    }

    // MARK: - Init

    public init() {
        self.capture = CloudMicCapture()
        self.whisper = WhisperLiveTranscriber()
        self.sarvam = SarvamProvider()
        NSLog("[DIAG] DualLiveProvider.init")
    }

    // MARK: - ASRProvider lifecycle

    public func start() async throws {
        let (stream, cont) = AsyncStream.makeStream(of: Partial.self)
        self.partialsStream = stream
        self.partialsContinuation = cont
        self.sarvamHasSpoken = false
        self.whisperPartialCount = 0
        self.sarvamSegmentCount = 0

        // 1) Start the single mic.
        let upstream: AsyncStream<Data>
        do {
            upstream = try capture.start()
        } catch {
            partialsContinuation?.finish()
            partialsContinuation = nil
            throw error
        }

        // 2) Fan out to two consumers via the broadcaster.
        let b = ChunkBroadcaster(upstream: upstream)
        self.broadcaster = b
        let whisperStream = b.newConsumer()
        let sarvamStream = b.newConsumer()
        NSLog("[DIAG] DualLiveProvider.start — Whisper+Sarvam mode, broadcaster live")

        // 3) Forward VU peaks via Sarvam-style energy partial so the
        //    UI level meter animates. Tag with .whisperLive so the
        //    freeze-last-good guard treats them as Whisper-side traffic
        //    (lowest priority; never displaces Sarvam transcripts).
        capture.onPeak = { [weak self] peak in
            guard let self else { return }
            Task { await self.emitEnergyPartial(peak) }
        }

        // 4) Hook Sarvam to the broadcaster's downstream.
        await sarvam.useExternalAudioStream(sarvamStream)
        do {
            try await sarvam.start()
        } catch {
            NSLog("[DIAG] DualLiveProvider Sarvam start FAILED: \(error.localizedDescription)")
            capture.stop()
            b.finish()
            self.broadcaster = nil
            partialsContinuation?.finish()
            partialsContinuation = nil
            throw error
        }

        // 5) Hook Whisper to its broadcaster downstream. If Whisper
        //    fails to load (model download issue, no network), continue
        //    in Sarvam-only fallback rather than aborting the session.
        do {
            try await whisper.start(audioStream: whisperStream)
        } catch {
            NSLog("[DIAG] DualLiveProvider Whisper start FAILED — continuing Sarvam-only: \(error.localizedDescription)")
        }

        // 6) Merge partials from both transcribers into our stream.
        let whisperPartials = await whisper.partials
        let sarvamPartials = await sarvam.partials

        whisperTask = Task { [weak self] in
            for await p in whisperPartials {
                await self?.handleWhisper(p)
            }
        }
        sarvamTask = Task { [weak self] in
            for await p in sarvamPartials {
                await self?.handleSarvam(p)
            }
        }
    }

    public func stop() async {
        NSLog("[DIAG] DualLiveProvider.stop — totalWhisperPartials=\(whisperPartialCount) totalSarvamSegments=\(sarvamSegmentCount)")
        capture.stop()

        // Children may have audio-consumer Tasks awaiting the broadcaster.
        // Finishing the broadcaster lets their for-await loops exit.
        broadcaster?.finish()
        broadcaster = nil

        // Drain both children. Sarvam internally waits for a 300 ms VAD
        // flush grace window in its stop(); that's the grace window for
        // the final segment too.
        await whisper.stop()
        await sarvam.stop()

        whisperTask?.cancel()
        sarvamTask?.cancel()
        whisperTask = nil
        sarvamTask = nil

        partialsContinuation?.finish()
        partialsContinuation = nil
    }

    // MARK: - Merge logic

    private func handleWhisper(_ p: Partial) {
        whisperPartialCount += 1
        // Once Sarvam has emitted anything, drop further Whisper
        // partials — Sarvam is canonical from that point on.
        if sarvamHasSpoken {
            return
        }
        NSLog("[DIAG] DualLiveProvider emit source=whisper text.len=\(p.text.count) head40=\"\(String(p.text.prefix(40)))\"")
        partialsContinuation?.yield(p)
    }

    private func handleSarvam(_ p: Partial) {
        // Transcript-less Sarvam recordPeak partials don't count as
        // "Sarvam has spoken" — we need an actual transcript to flip
        // the flag.
        if !p.text.isEmpty {
            sarvamHasSpoken = true
            sarvamSegmentCount += 1
            NSLog("[DIAG] DualLiveProvider emit source=sarvam text.len=\(p.text.count) head40=\"\(String(p.text.prefix(40)))\"")
        }
        partialsContinuation?.yield(p)
    }

    private func emitEnergyPartial(_ peak: Float) {
        // Match Sarvam's threshold for the "speaking" indicator so
        // the VU bar behaves identically across modes.
        let speaking = peak > 0.02
        partialsContinuation?.yield(Partial(
            text: "",
            latin: "",
            gurmukhi: "",
            isSpeaking: speaking,
            bufferEnergy: peak,
            source: .whisperLive  // lowest-priority tag; empty text
                                  // partials never displace transcripts
                                  // via the freeze-last-good guard
        ))
    }
}
