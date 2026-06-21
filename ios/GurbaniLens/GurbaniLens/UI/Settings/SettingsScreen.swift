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
///       b. (Phase A.4b will add Cloud sub-section here — DO NOT TOUCH)
///   4. Default display script
///   5. Default translation
///   6. About
struct SettingsScreen: View {
    let onBack: () -> Void

    @AppStorage("settings.searchMode") private var searchModeRaw: String = SearchModeChoice.live.rawValue
    @AppStorage("settings.silenceThreshold") private var silenceThresholdRaw: String = SilenceThresholdChoice.balanced.rawValue
    @AppStorage("settings.asrProvider") private var asrProviderRaw: String = ASRProviderId.whisperKit.rawValue
    @AppStorage("settings.whisperModel") private var whisperModelRaw: String = WhisperModel.largeV3.rawValue
    @AppStorage("settings.script") private var scriptRaw: String = ScriptChoice.both.rawValue
    @AppStorage("settings.translation") private var translationRaw: String = TranslationChoice.manmohanSingh.rawValue

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

            // Phase A.4b will append a "Cloud" sub-section here:
            //   cloudRecognitionSubsection
        }
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
