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
    @AppStorage("settings.asrProvider") private var asrProviderRaw: String = ASRProviderId.whisperKit.rawValue
    @AppStorage("settings.whisperModel") private var whisperModelRaw: String = WhisperModel.largeV3.rawValue
    @AppStorage("settings.script") private var scriptRaw: String = ScriptChoice.both.rawValue
    @AppStorage("settings.translation") private var translationRaw: String = TranslationChoice.manmohanSingh.rawValue

    // Phase A.4b cloud + debug settings.
    @AppStorage(CloudTrialPolicy.enabledKey) private var cloudEnabled: Bool = false
    @AppStorage(CloudTrialPolicy.remainingKey) private var cloudFreeTrialRemaining: Int = CloudTrialPolicy.monthlyAllowance
    @AppStorage(CloudTrialPolicy.lastResetMonthKey) private var lastTrialResetMonth: String = ""
    @AppStorage("settings.debugCompareEnabled") private var debugCompareEnabled: Bool = false

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
                VStack(alignment: .leading, spacing: 4) {
                    CloudProviderRow(
                        title: ASRProviderId.dual.cloudDisplayName,
                        subtitle: "Live word-by-word as you speak, refined to Punjabi when Sarvam catches up",
                        selected: asrProviderRaw == ASRProviderId.dual.rawValue,
                        onTap: { asrProviderRaw = ASRProviderId.dual.rawValue }
                    )
                    CloudProviderRow(
                        title: ASRProviderId.sarvam.cloudDisplayName,
                        subtitle: "Indian language SOTA, ₹30/hour",
                        selected: asrProviderRaw == ASRProviderId.sarvam.rawValue,
                        onTap: { asrProviderRaw = ASRProviderId.sarvam.rawValue }
                    )
                    CloudProviderRow(
                        title: ASRProviderId.gemini.cloudDisplayName,
                        subtitle: "Google multimodal, lower cost",
                        selected: asrProviderRaw == ASRProviderId.gemini.rawValue,
                        onTap: { asrProviderRaw = ASRProviderId.gemini.rawValue }
                    )
                }

                HStack {
                    Text("Free trial: \(cloudFreeTrialRemaining) of \(CloudTrialPolicy.monthlyAllowance) cloud searches this month")
                        .font(.system(size: 12))
                        .foregroundColor(cloudFreeTrialRemaining > 0
                                         ? Theme.onSurfaceVariant
                                         : .red)
                    Spacer()
                }
                .padding(.top, 4)

                Text("Cloud providers require internet. Your audio is sent to the provider — Sarvam (api.sarvam.ai) or Google (generativelanguage.googleapis.com) — and processed there. Local Whisper keeps audio fully on device.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.onSurfaceVariant)
                    .padding(.top, 2)
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
                    // Default cloud pick = Dual (Whisper live + Sarvam
                    // refine) — best of both: instant text + Punjabi
                    // quality at VAD boundaries. Sarvam-only and Gemini
                    // remain selectable below for users who explicitly
                    // want a single backend.
                    if asrProviderRaw == ASRProviderId.whisperKit.rawValue {
                        asrProviderRaw = ASRProviderId.dual.rawValue
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
                ForEach(WhisperModel.allCases) { opt in
                    WhisperModelRow(
                        model: opt,
                        selected: opt.rawValue == whisperModelRaw,
                        onTap: { whisperModelRaw = opt.rawValue }
                    )
                }
            }
            Text("Whisper runs entirely on device. No internet needed after the model has been downloaded.")
                .font(.system(size: 12))
                .foregroundColor(Theme.onSurfaceVariant)
                .padding(.top, 4)
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
        case .whisperKit: return "On-device Whisper"
        case .sarvam:     return "Sarvam Saaras-v3"
        case .gemini:     return "Gemini 2.5 Flash"
        case .dual:       return "Dual (Whisper live + Sarvam refine)"
        }
    }
}

// MARK: - Whisper-model row (richer than RadioRow — shows name + size)

private struct WhisperModelRow: View {
    let model: WhisperModel
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Theme.primary : Theme.onSurfaceVariant)
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(Theme.onSurface)
                        .multilineTextAlignment(.leading)
                    Text("\(model.shortDisplayName)  ·  \(model.approximateSize)")
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
