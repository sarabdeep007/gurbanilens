import SwiftUI

/// v2 search-mode toggle. `.live` is the v2 "search as you speak" flow
/// (mic streams, results update live as Whisper transcribes incrementally);
/// `.oneShot` is the v1 "tap, recite, tap Done, wait, see result" flow.
/// Both go through the same Results / Shabad screens on commit.
///
/// Default for new installs is `.live` per the v2 spec
/// (docs/PHASE_2A_V2_INCREMENTAL_SEARCH.md decision §10). `.oneShot`
/// stays for noisy environments, slow connections, and as a fallback if
/// the v2 streaming pipeline misbehaves on a given device.
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

/// v2 live-mode silence-VAD sensitivity. WhisperKit's
/// `AudioStreamTranscriber.silenceThreshold` controls how aggressively the
/// stream auto-finishes on a quiet moment. Phase A defaulted to 0.3 which
/// Deep's 2026-06-20 device test showed wipes mid-sentence on a brief
/// breath pause. v2 default is 0.6; power users can tune.
enum SilenceThresholdChoice: String, CaseIterable, Identifiable {
    case loose      // 0.4 — most permissive, tolerates short pauses
    case balanced   // 0.6 — Phase A.1 default
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

enum WhisperModelChoice: String, CaseIterable, Identifiable {
    case tiny, base, small, medium
    var id: String { rawValue }
    var display: String {
        switch self {
        case .tiny:   return "tiny (40 MB)"
        case .base:   return "base (150 MB)"
        case .small:  return "small (250 MB) — bundled"
        case .medium: return "medium (500 MB) — download"
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

/// v1 Settings — model size, display script, default translation, About.
/// Mirrors `android/.../ui/settings/SettingsScreen.kt`.
struct SettingsScreen: View {
    let onBack: () -> Void

    @AppStorage("settings.searchMode") private var searchModeRaw: String = SearchModeChoice.live.rawValue
    @AppStorage("settings.silenceThreshold") private var silenceThresholdRaw: String = SilenceThresholdChoice.balanced.rawValue
    @AppStorage("settings.model") private var modelRaw: String = WhisperModelChoice.small.rawValue
    @AppStorage("settings.script") private var scriptRaw: String = ScriptChoice.both.rawValue
    @AppStorage("settings.translation") private var translationRaw: String = TranslationChoice.manmohanSingh.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                section("Whisper model") {
                    ForEach(WhisperModelChoice.allCases) { opt in
                        RadioRow(label: opt.display, selected: opt.rawValue == modelRaw) {
                            modelRaw = opt.rawValue
                        }
                    }
                }
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
                Spacer().frame(height: 4)
                aboutBlock
                Spacer().frame(height: 24)
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
            Text("GurbaniLens — v1 voice-search")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Theme.onSurface)
            Text("Built as Seva by Taaj Studios. Free for individuals and Gurdwaras forever. No ads, no tracking.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
            Text("ASR: whisper.cpp on-device · Matcher: rapidfuzz-equivalent Indel-LCS · SGGS data: shabados/database v4.8.7.")
                .font(.system(size: 14))
                .foregroundColor(Theme.onSurfaceVariant)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

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
