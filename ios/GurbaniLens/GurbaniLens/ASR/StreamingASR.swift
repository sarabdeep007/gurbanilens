import Foundation
import GurbaniLensCore

/// **Phase A.4a facade.** v2's streaming ASR is now provider-pluggable
/// via the ``ASRProvider`` protocol. StreamingASR's public API stays
/// what every downstream caller (VoiceSearchSession, AppContainer,
/// LiveResultsScreen) already uses:
///
///   let asr = StreamingASR()
///   let stream = try await asr.partials()
///   for await partial in stream { ... }
///   await asr.stop()
///
/// Internally it picks a provider based on
/// `@AppStorage("settings.asrProvider")`:
///
///   - `.whisperKit` → `WhisperKitProvider` (Phase A.4a, default,
///     on-device, large-v3 by default)
///   - `.sarvam` / `.gemini` → **A.4b's responsibility.** Until that
///     dispatch merges, both cases fall back to WhisperKitProvider with
///     a DIAG warning.
///
/// Why a facade rather than have callers talk to providers directly:
/// VoiceSearchSession + AppContainer were stable through A.3; the
/// pluggable-provider concept is a v2 architecture seam, not a UX
/// seam. Keeping it inside the facade means we can add / swap
/// providers without touching the session / nav layers.
public actor StreamingASR {

    // MARK: - Public surface (preserved from Phase A.3)

    public enum StreamingError: LocalizedError {
        case alreadyStreaming
        case providerStartFailed(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .alreadyStreaming:
                return "StreamingASR is already running."
            case .providerStartFailed(let e):
                return "ASR provider start failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Provider lookup

    /// Explicitly nonisolated so the `nonisolated var activeProviderId`
    /// getter (and friends) can read it without a Swift 6 actor-isolation
    /// diagnostic. `any ASRProvider` is Sendable (ASRProvider: Actor →
    /// Sendable) and the property is `let`, both prerequisites for
    /// nonisolated stored access.
    private nonisolated let provider: any ASRProvider
    private var streamInFlight: Bool = false

    /// Read the provider id from `@AppStorage` synchronously. UserDefaults
    /// is safe to access from any thread; we intentionally avoid pulling
    /// in SwiftUI's `@AppStorage` wrapper since this actor isn't a View.
    public nonisolated static func currentProviderId() -> ASRProviderId {
        let raw = UserDefaults.standard.string(forKey: "settings.asrProvider")
            ?? ASRProviderId.whisperKit.rawValue
        return ASRProviderId(rawValue: raw) ?? .whisperKit
    }

    public nonisolated static func currentWhisperModel() -> WhisperModel {
        // Default: .medium (~770 MB). small drifts to Telugu on
        // Punjabi audio (Phase 1) — unacceptable for Whisper-only
        // mode. large-v3 (1.5 GB) is too heavy as the install
        // baseline; medium is the right balance. Users can still
        // pick either explicitly in Settings.
        let raw = UserDefaults.standard.string(forKey: "settings.whisperModel")
            ?? WhisperModel.medium.rawValue
        return WhisperModel(rawValue: raw) ?? .medium
    }

    public nonisolated static func currentSilenceThreshold() -> Float {
        let raw = UserDefaults.standard.string(forKey: "settings.silenceThreshold")
            ?? SilenceThresholdChoice.balanced.rawValue
        return SilenceThresholdChoice(rawValue: raw)?.value
            ?? SilenceThresholdChoice.balanced.value
    }

    /// Default-init reads Settings and builds the appropriate provider.
    /// Callers in AppContainer.ensureStreamingAsr use this initialiser.
    public init() {
        let configuredProviderId = Self.currentProviderId()
        let model = Self.currentWhisperModel()
        let silenceThreshold = Self.currentSilenceThreshold()

        // "Disable on-device Whisper" — testing toggle that forces
        // cloud-only mode regardless of the user's regular pick. When
        // ON, both `.whisperKit` and `.dual` get substituted with
        // `.sarvam` so we can validate Sarvam (or Gemini if the user
        // picks it explicitly) in isolation. Cloud A/B comparison
        // needs Whisper out of the path entirely.
        let disableWhisper = UserDefaults.standard.bool(forKey: "settings.disableWhisper")
        let providerId: ASRProviderId
        if disableWhisper, configuredProviderId == .whisperKit || configuredProviderId == .dual {
            NSLog("[DIAG] StreamingASR.init disableWhisper=true — substituting \(configuredProviderId.rawValue) → sarvam")
            providerId = .sarvam
        } else {
            providerId = configuredProviderId
        }

        switch providerId {
        case .whisperKit:
            self.provider = WhisperKitProvider(model: model, silenceThreshold: silenceThreshold)
        case .sarvam:
            // Phase A.4b: real Sarvam Saaras-v3 streaming. API key
            // injected at build time by scripts/inject_env_to_plist.sh
            // (reads .env at repo root, writes SARVAM_API_KEY into the
            // built Info.plist). If the key is missing, start() throws
            // SarvamError.missingApiKey and the error propagates to
            // session.setError — caller flips the Settings toggle off
            // and the next session uses WhisperKit.
            self.provider = SarvamProvider()
        case .gemini:
            // Phase A.4b: real Gemini 2.5 Flash chunked audio. Same
            // .env injection contract + same missing-key error path.
            self.provider = GeminiProvider()
        case .dual:
            // Phase A.4d: WhisperKit-small live + Sarvam refine. Single
            // mic stream fans out via ChunkBroadcaster to both. Cloud
            // half still needs SARVAM_API_KEY; on-device half loads the
            // Whisper small model on first start (~150 MB).
            self.provider = DualLiveProvider()
        }

        NSLog("[DIAG] StreamingASR.init selectedProvider=\(providerId.rawValue) effectiveProvider=\(self.provider.providerId.rawValue) model=\(model.rawValue) silenceThreshold=\(silenceThreshold)")
    }

    /// Custom-provider init for tests / Phase A.4b cross-wiring.
    public init(provider: any ASRProvider) {
        self.provider = provider
        NSLog("[DIAG] StreamingASR.init customProvider=\(provider.providerId.rawValue)")
    }

    // MARK: - Public API

    /// Start the underlying provider and return its partial-transcript
    /// stream. Throws if already streaming or if the provider failed to
    /// start (e.g. WhisperKit model download / load error).
    public func partials() async throws -> AsyncStream<Partial> {
        if streamInFlight { throw StreamingError.alreadyStreaming }
        streamInFlight = true
        do {
            try await provider.start()
        } catch {
            streamInFlight = false
            throw StreamingError.providerStartFailed(underlying: error)
        }
        return await provider.partials
    }

    /// Stop the provider; idempotent.
    public func stop() async {
        await provider.stop()
        streamInFlight = false
    }

    // MARK: - Introspection

    /// The active provider's id (useful for showing a model pill in the
    /// LiveResultsScreen footer).
    public nonisolated var activeProviderId: ASRProviderId { provider.providerId }
    public nonisolated var activeProviderDisplayName: String { provider.displayName }
    public nonisolated var activeProviderRequiresNetwork: Bool { provider.requiresNetwork }

    /// WhisperKit-only: download-progress stream. Used by the
    /// LiveResultsScreen to render a "Downloading large-v3 …" header
    /// the first time the user enables the model.
    public nonisolated var whisperDownloadProgress: AsyncStream<Float>? {
        guard let wk = provider as? WhisperKitProvider else { return nil }
        return wk.downloadProgress
    }
}
