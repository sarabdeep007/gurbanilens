import SwiftUI

/// v2 search-mode toggle. `.live` is the v2 "search as you speak" flow;
/// `.oneShot` is the v1 "tap, recite, tap Done, wait, see result" flow.
enum SearchModeChoice: String, CaseIterable, Identifiable {
    case live
    case oneShot

    var id: String { rawValue }
    var display: String {
        switch self {
        case .live:    return "Live (recommended)"
        case .oneShot: return "One-shot — tap, recite, tap Done"
        }
    }
}

/// v2 live-mode silence-VAD sensitivity. Default `balanced` (0.6).
enum SilenceThresholdChoice: String, CaseIterable, Identifiable {
    case loose      // 0.4 — most permissive
    case balanced   // 0.6 — default
    case tight      // 0.8 — stop quickly on silence

    var id: String { rawValue }
    var value: Float {
        switch self {
        case .loose:    return 0.4
        case .balanced: return 0.6
        case .tight:    return 0.8
        }
    }
    var display: String {
        switch self {
        case .loose:    return "Loose — tolerate breaths and short pauses"
        case .balanced: return "Balanced (recommended)"
        case .tight:    return "Tight — stop quickly after silence"
        }
    }
}

enum ScriptChoice: String, CaseIterable, Identifiable {
    case gurmukhi, transliteration, both
    var id: String { rawValue }
    var display: String {
        switch self {
        case .gurmukhi:        return "Unicode Gurmukhi"
        case .transliteration: return "Latin transliteration"
        case .both:            return "Show both"
        }
    }
}

enum TranslationChoice: String, CaseIterable, Identifiable {
    case none, manmohanSingh, santSinghKhalsa, punjabiTeeka
    var id: String { rawValue }
    var display: String {
        switch self {
        case .none:            return "None"
        case .manmohanSingh:   return "Bhai Manmohan Singh"
        case .santSinghKhalsa: return "Sant Singh Khalsa"
        case .punjabiTeeka:    return "Punjabi Teeka (Prof. Sahib Singh)"
        }
    }
}

/// Settings — scroll-wrapped per Phase A.4a (Deep flagged on small
/// iPhones that content overflowed). Sections, top to bottom:
///   1. Search mode (.live / .oneShot)
///   2. Live silence sensitivity (loose / balanced / tight)
///   3. **Voice recognition** (Phase A.4a parent)
///       a. Local model (Whisper) — picker bound to settings.whisperModel
///       b. Cloud (Phase A.4b) — toggle + provider picker + free-trial counter
///   4. Default display script
///   5. Default translation
///   6. About (5-tap on Version unlocks Compare debug mode — Phase A.4b)
struct SettingsScreen: View {
    let onBack: () -> Void

    @AppStorage("settings.searchMode") private var searchModeRaw: String = SearchModeChoice.live.rawValue
    @AppStorage("settings.silenceThreshold") private var silenceThresholdRaw: String = SilenceThresholdChoice.balanced.rawValue
    // 2026-06-25: default flipped from .whisperKit → .gurbanilensCloud
    // (v1 production default — self-hosted IndicConformer Punjabi at
    // asr.gurbanilens.com, free for end users). The cloud-master gate
    // in StreamingASR.init still converts this back to .whisperKit
    // when cloud is disabled, so offline-only users still get Whisper.
    @AppStorage("settings.asrProvider") private var asrProviderRaw: String = ASRProviderId.gurbanilensCloud.rawValue
    // Default = .medium (~770 MB). small drifts to Telugu on Punjabi
    // (Phase 1) — unacceptable for Whisper-only mode where there's no
    // cloud fallback. large-v3 (1.5 GB) is too heavy as the install
    // baseline. medium is Punjabi-competent without the prohibitive
    // download. Users wanting maximum accuracy can pick .largeV3 from
    // the model picker below.
    @AppStorage("settings.whisperModel") private var whisperModelRaw: String = WhisperModel.medium.rawValue
    @AppStorage("settings.script") private var scriptRaw: String = ScriptChoice.both.rawValue
    @AppStorage("settings.translation") private var translationRaw: String = TranslationChoice.manmohanSingh.rawValue

    // 2026-06-25: default flipped false → true so v1's
    // .gurbanilensCloud asrProvider default actually applies on fresh
    // installs (otherwise the onAppear snap would immediately force
    // it to .whisperKit). The GurbaniLens Cloud endpoint is free for
    // end users, so cloud-on-by-default is the correct UX.
    @AppStorage(CloudTrialPolicy.enabledKey) private var cloudEnabled: Bool = true
    @AppStorage(CloudTrialPolicy.remainingKey) private var cloudFreeTrialRemaining: Int = CloudTrialPolicy.monthlyAllowance
    @AppStorage(CloudTrialPolicy.lastResetMonthKey) private var lastTrialResetMonth: String = ""
    @AppStorage("settings.debugCompareEnabled") private var debugCompareEnabled: Bool = false

    // Phase A.4d UX flow: auto-open the matched Shabad when the live
    // matcher returns a single high-confidence (≥90) result. Default
    // ON. Off for users who prefer always seeing the result list.
    @AppStorage("settings.autoOpenExactMatches") private var autoOpenExactMatches: Bool = true

    // 2026-06-24 testing toggle: force the StreamingASR factory to
    // substitute `.whisperKit` / `.dual` with `.sarvam` so cloud
    // providers can be validated in isolation. Default OFF — the
    // on-device path is the long-term default. See StreamingASR.init.
    @AppStorage("settings.disableWhisper") private var disableWhisper: Bool = false

    // Brief #8 (2026-06-27): Raagi Mode opt-in. When ON, the home
    // mic tap opens RaagiModeScreen (continuous-listening kirtan
    // follow) instead of LiveResultsScreen (single quick search).
    // Default OFF — quick-search is the v1 default.
    @AppStorage("settings.raagiMode") private var raagiModeEnabled: Bool = false
    /// Brief #9-iOS (2026-06-27): streaming WebSocket mode toggle.
    /// Default OFF — only the buffered behaviour ships first; user
    /// flips ON for the real-time experience once the server endpoint
    /// is live.
    @AppStorage("settings.streamingModeEnabled") private var streamingModeEnabled: Bool = false

    @State private var showResetWhisperToast: Bool = false

    // Local UI state for the version-tap unlock + trial-exhausted modal.
    @State private var versionTapCount: Int = 0
    @State private var versionTapLastTime: Date = .distantPast
    @State private var showTrialExhaustedAlert: Bool = false
    @State private var showDebugUnlockedAlert: Bool = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 24) {
                section("Search mode") {
                    ForEach(SearchModeChoice.allCases) { opt in
                        RadioRow(label: opt.display, selected: opt.rawValue == searchModeRaw) {
                            searchModeRaw = opt.rawValue
                        }
                    }
                }
                section("Live silence sensitivity") {
                    ForEach(SilenceThresholdChoice.allCases) { opt in
                        RadioRow(label: opt.display, selected: opt.rawValue == silenceThresholdRaw) {
                            silenceThresholdRaw = opt.rawValue
                        }
                    }
                }

                section("Raagi Mode") {
                    Toggle(isOn: $raagiModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Continuous kirtan-follow mode")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.onSurface)
                            Text("When ON, the mic button opens Raagi Mode — the app listens continuously, opens the matching Shabad as the raagi sings, and follows along Pangti by Pangti. Default OFF (quick search).")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .tint(Theme.primary)
                    .padding(.vertical, 4)
                    Toggle(isOn: $streamingModeEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Streaming mode (beta)")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.onSurface)
                            Text("Real-time pangti detection. Sends audio continuously to the GurbaniLens server, which streams matches back as you sing — sub-second latency. Requires a good network connection. Default OFF (buffered local matching).")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .tint(Theme.primary)
                    .padding(.vertical, 4)
                }

                section("Auto-open exact matches") {
                    Toggle(isOn: $autoOpenExactMatches) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open Shabad automatically")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.onSurface)
                            Text("When the matcher is highly confident (single exact-match), open the Shabad after a 1-second confirmation pause. Turn off if you prefer to always see the result list.")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.onSurfaceVariant)
                        }
                    }
                    .tint(Theme.primary)
                    .padding(.vertical, 4)
                }

                // Voice recognition parent section.
                voiceRecognitionSection

                section("Default display script") {
                    ForEach(ScriptChoice.allCases) { opt in
                        RadioRow(label: opt.display, selected: opt.rawValue == scriptRaw) {
                            scriptRaw = opt.rawValue
                        }
                    }
                }
                section("Default translation") {
                    ForEach(TranslationChoice.allCases) { opt in
                        RadioRow(label: opt.display, selected: opt.rawValue == translationRaw) {
                            translationRaw = opt.rawValue
                        }
                    }
                }
                Spacer().frame(height: 12)
                aboutBlock
                // Extra bottom padding so the scroll-extreme leaves
                // breathing room above the safe area, especially when
                // Phase A.4b adds the Cloud sub-section below Local
                // model — the user shouldn't have to fight the home
                // indicator to reach About.
                Spacer().frame(height: 48)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").foregroundColor(Theme.onBackground)
                }.accessibilityLabel("Back")
            }
        }
        .onAppear {
            // Roll the trial counter forward to the current month if we
            // crossed a month boundary since last open.
            CloudTrialPolicy.resetIfNewMonth(
                lastResetMonth: $lastTrialResetMonth,
                remaining: $cloudFreeTrialRemaining
            )
            // Normalise: if the user previously picked a cloud provider
            // but cloudEnabled is off (e.g. fresh install / migration),
            // snap asrProvider back to WhisperKit.
            if !cloudEnabled && asrProviderRaw != ASRProviderId.whisperKit.rawValue {
                asrProviderRaw = ASRProviderId.whisperKit.rawValue
            }
        }
        .alert("Free trial used up", isPresented: $showTrialExhaustedAlert, actions: {
            Button("OK") { showTrialExhaustedAlert = false }
        }, message: {
            Text("Your 50 free cloud searches this month are gone. Switch back to Local Whisper to keep searching offline — or purchase a subscription (coming soon).")
        })
        .alert("Compare mode unlocked", isPresented: $showDebugUnlockedAlert, actions: {
            Button("OK") { showDebugUnlockedAlert = false }
        }, message: {
            Text("A Compare button is now visible in the Live Listening toolbar. Tap it to A/B test WhisperKit / Sarvam / Gemini on one recording.")
        })
    }

    // MARK: - Voice recognition (Phase A.4a + A.4b shared parent)
    //
    // A.4a owns the "Local model (Whisper)" sub-section below. A.4b's
    // parallel agent will add a "Cloud" sub-section UNDER this same
    // parent header, between Local model and the next Settings
    // section. To avoid merge conflicts they should add a new
    // computed property `cloudRecognitionSubsection` and append it
    // inside `voiceRecognitionSection` below the local-model
    // sub-section. **Do not refactor the parent header.**

    private var voiceRecognitionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header.
            Text("Voice recognition")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.primary)

            // A.4a sub-section: Local model picker (Whisper).
            localModelSubsection

            // A.4b sub-section: Cloud provider toggle + picker + free-trial.
            cloudRecognitionSubsection
        }
    }

    // A.4b-owned sub-section. Toggle defaults to OFF; flipping ON exposes
    // a Sarvam / Gemini radio pair and binds the choice to
    // settings.asrProvider. Flipping OFF snaps asrProvider back to
    // WhisperKit so a stale cloud selection can't accidentally win when
    // StreamingASR.init reads @AppStorage on the next live session.
    private var cloudRecognitionSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.onSurfaceVariant)

            Toggle(isOn: cloudEnabledBinding) {
                Text("Cloud voice recognition")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.onSurface)
            }
            .tint(Theme.primary)
            .padding(.vertical, 4)

            if cloudEnabled {
                // Provider picker — v1 production list.
                // GurbaniLens Cloud is the v1 recommended default
                // (added 2026-06-25, self-hosted IndicConformer
                // Punjabi at asr.gurbanilens.com, free for end users).
                //
                // Sarvam HIDDEN (2026-06-25): GurbaniLens Cloud now
                // covers the high-quality-Punjabi cloud slot at zero
                // per-search cost. The ASRProviderId.sarvam enum
                // case + SarvamProvider implementation are kept in
                // code (DualLiveProvider's WhisperLiveTranscriber +
                // Sarvam refinement still uses it internally; Compare
                // debug references it too) but never exposed to end
                // users. If you're about to re-add the Sarvam row,
                // re-read this comment first.
                //
                // Gemini HIDDEN (a05f144 / 2026-06-24): hallucinates
                // plausible-looking Gurbani sacred text regardless of
                // input — unusable for STT.
                //
                // Dual mode HIDDEN: still works, still costs a Sarvam
                // call per session. Once GurbaniLens Cloud proves
                // itself in v1 we can decide whether to retire Dual
                // entirely or keep as a debug option.
                VStack(alignment: .leading, spacing: 4) {
                    CloudProviderRow(
                        title: ASRProviderId.gurbanilensCloud.cloudDisplayName,
                        subtitle: "Self-hosted IndicConformer Punjabi · free · fast",
                        selected: asrProviderRaw == ASRProviderId.gurbanilensCloud.rawValue,
                        onTap: { asrProviderRaw = ASRProviderId.gurbanilensCloud.rawValue }
                    )
                }

                Text("GurbaniLens Cloud is free for end users (Seva-funded). Your audio is sent to asr.gurbanilens.com over HTTPS and processed there; nothing is stored. Requires internet. Local Whisper keeps audio fully on device for offline use.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.top, 6)
            } else {
                Text("Off: voice search uses on-device Whisper only.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.top, 2)
            }
        }
    }

    /// Bound toggle that snaps `asrProvider` back to `.whisperKit` on OFF
    /// and (on first ON if nothing's selected) defaults to Sarvam.
    private var cloudEnabledBinding: Binding<Bool> {
        Binding(
            get: { cloudEnabled },
            set: { newValue in
                cloudEnabled = newValue
                if newValue {
                    // Default cloud pick = GurbaniLens Cloud (the v1
                    // recommended provider — free, fast, Punjabi-
                    // specific). Only override an existing pick if it
                    // was the offline default; respect explicit cloud
                    // selections (Dual etc. for power users via the
                    // hidden enum).
                    if asrProviderRaw == ASRProviderId.whisperKit.rawValue {
                        asrProviderRaw = ASRProviderId.gurbanilensCloud.rawValue
                    }
                } else {
                    asrProviderRaw = ASRProviderId.whisperKit.rawValue
                }
            }
        )
    }

    // A.4a-owned sub-section.
    private var localModelSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local model (Whisper)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 4) {
                // Production picker: medium only.
                //
                // Whisper-large-v3 was hidden 2026-06-24 after Deep's
                // on-device test crashed the app with iOS memory
                // pressure (Xcode "too much memory" pop-up, immediate
                // re-crash on relaunch). Large-v3 in CPU+GPU mode (the
                // only mode that loads — ANE refuses with Program load
                // failure 0x20004) keeps 2–3 GB tensors in working
                // RAM per inference. iOS jetsam kills apps exceeding
                // ~3–4 GB on iPhone hardware. Verdict: large-v3 is
                // unusable on consumer iPhones. If we ship to iPad Pro
                // M-series or Mac Catalyst in future, revisit and
                // expose large-v3 conditionally on high-RAM targets.
                //
                // Whisper-small was hidden earlier (drifts to Telugu
                // on clean Punjabi — Phase 1 finding). Tiny / base
                // never tested; same family, no reason to expect
                // better Punjabi behaviour than small.
                //
                // WhisperModel.largeV3 / .small / .base / .tiny stay
                // in the enum — WhisperLiveTranscriber hardcodes
                // "openai_whisper-small" for Dual-mode live half
                // (Sarvam refines so small's quality gap is invisible
                // there), and Compare-mode debug + future device tiers
                // may still reference them.
                let userFacingModels: [WhisperModel] = [.medium]
                ForEach(userFacingModels) { opt in
                    WhisperModelRow(
                        model: opt,
                        selected: opt.rawValue == whisperModelRaw,
                        recommended: opt == .medium,
                        onTap: { whisperModelRaw = opt.rawValue }
                    )
                }
            }
            Text("Whisper-medium runs entirely on device. No internet needed after the first download. For higher accuracy when online, enable cloud and choose Sarvam.")
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
                .padding(.top, 4)

            // Cloud-only test toggle. Lives in the local-model section
            // so users see it adjacent to the Whisper picker — its
            // effect is to force the StreamingASR factory to bypass
            // whichever Whisper model is selected here.
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $disableWhisper) {
                    Text("Disable on-device Whisper")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.onSurface)
                }
                .tint(Theme.primary)
                Text("Testing only. Forces cloud providers (Sarvam, Gemini) and bypasses Whisper. Use to isolate cloud quality.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            .padding(.top, 8)

            // Reset Whisper models — manual escape hatch for the silent
            // download-stuck case the auto-corruption catch can't see.
            // Wipes both the on-disk huggingface cache and the in-memory
            // WhisperKitPipeCache; next mic tap starts fresh.
            Button(role: .destructive) {
                WhisperKitProvider.resetAllModels()
                showResetWhisperToast = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text("Reset Whisper models")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .alert("Whisper models reset", isPresented: $showResetWhisperToast, actions: {
                Button("OK") { showResetWhisperToast = false }
            }, message: {
                Text("Cached model files cleared. The next Listen tap will download fresh.")
            })
        }
    }

    // MARK: - Section helper

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.primary)
            content()
        }
    }

    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GurbaniLens — v2 voice-search")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onSurface)
            Text("Built as Seva by Taaj Studios. Free for individuals and Gurdwaras forever. No ads, no tracking.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            Text("ASR: WhisperKit (Whisper large-v3 default) · Matcher: rapidfuzz-equivalent Indel-LCS · SGGS data: shabados/database v4.8.7.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            // Tapping the Version line 5 times within ~2 sec unlocks the
            // Compare debug screen (multi-provider A/B test). Hidden so
            // we don't expose it to end users; meant for Deep + future
            // dataset-collection sevadaars.
            Text(versionLine)
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant.opacity(0.6))
                .padding(.top, 4)
                .contentShape(Rectangle())
                .onTapGesture { handleVersionTap() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var versionLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let debugSuffix = debugCompareEnabled ? " · debug" : ""
        return "Version \(v) (\(b))\(debugSuffix)"
    }

    private func handleVersionTap() {
        let now = Date()
        if now.timeIntervalSince(versionTapLastTime) > 2.0 {
            versionTapCount = 0
        }
        versionTapLastTime = now
        versionTapCount += 1
        if versionTapCount >= 5 {
            versionTapCount = 0
            if !debugCompareEnabled {
                debugCompareEnabled = true
                showDebugUnlockedAlert = true
                NSLog("[DIAG] SettingsScreen debug Compare mode UNLOCKED (5-tap on version)")
            } else {
                debugCompareEnabled = false
                NSLog("[DIAG] SettingsScreen debug Compare mode disabled (5-tap on version while enabled)")
            }
        }
    }
}

// MARK: - Cloud provider row

private struct CloudProviderRow: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Theme.primary : Theme.onSurfaceVariant)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(Theme.onSurface)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.onSurfaceVariant)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cloud provider display-name helper

private extension ASRProviderId {
    var cloudDisplayName: String {
        switch self {
        case .whisperKit:       return "On-device Whisper"
        case .sarvam:           return "Sarvam Saaras-v3"
        case .gemini:           return "Gemini 2.5 Flash"
        case .dual:             return "Dual (Whisper live + Sarvam refine)"
        case .gurbanilensCloud: return "GurbaniLens Cloud (recommended)"
        }
    }
}

// MARK: - Whisper-model row (richer than RadioRow — shows name + size)

private struct WhisperModelRow: View {
    let model: WhisperModel
    let selected: Bool
    let recommended: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Theme.primary : Theme.onSurfaceVariant)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 15, weight: selected ? .semibold : .regular))
                            .foregroundColor(Theme.onSurface)
                            .multilineTextAlignment(.leading)
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.primary.opacity(0.18))
                                .foregroundColor(Theme.primary)
                                .clipShape(Capsule())
                        }
                    }
                    Text("\(model.shortDisplayName)  ·  \(model.approximateSize)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plain radio row (other settings sections)

private struct RadioRow: View {
    let label: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Theme.primary : Theme.onSurfaceVariant)
                    .font(.system(size: 20))
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.onSurface)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
