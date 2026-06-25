import SwiftUI
import GurbaniLensCore

enum ScriptToggle: String, CaseIterable, Identifiable {
    case gurmukhi = "Gurmukhi"
    case transliteration = "Transliteration"
    case both = "Both"
    var id: String { rawValue }
}

/// v1 Shabad — full-shabad reader with script + English toggles, focused-line
/// scroll-to. Mirrors `android/.../ui/shabad/ShabadScreen.kt`.
struct ShabadScreen: View {
    let title: String
    let lines: [Line]
    let focusLineId: String?
    let onBack: () -> Void

    @State private var script: ScriptToggle = .both
    @State private var showEnglish: Bool = true

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ScriptToggle.allCases) { opt in
                    ToggleChip(label: opt.rawValue, selected: script == opt) { script = opt }
                }
                Spacer()
                ToggleChip(label: "English", selected: showEnglish) {
                    showEnglish.toggle()
                }
            }
            .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(lines, id: \.id) { line in
                            LineRow(line: line,
                                    script: script,
                                    showEnglish: showEnglish,
                                    focused: line.id == focusLineId)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    if let focus = focusLineId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(focus, anchor: .center) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themed()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").foregroundColor(Theme.onBackground)
                }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up").foregroundColor(Theme.onBackground)
                }
                .accessibilityLabel("Share")
            }
        }
    }

    private var shareText: String {
        // Use Gurmukhi (Unicode if available, raw fallback) so the recipient
        // sees the actual Pangti. Translation isn't in our DB yet (see
        // STATUS.md — Anvaad-augmented build pending).
        lines.map { $0.gurmukhiUnicode ?? Gurmukhi.fromAnmolLipi($0.gurmukhi) }
            .joined(separator: "\n") + "\n\n— GurbaniLens"
    }
}

private struct LineRow: View {
    let line: Line
    let script: ScriptToggle
    let showEnglish: Bool
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if script != .transliteration {
                Text(line.gurmukhiUnicode ?? Gurmukhi.fromAnmolLipi(line.gurmukhi))
                    .font(.notoSerifGurmukhi(22, weight: .medium))
                    .foregroundColor(Theme.onSurface)
            }
            if script != .gurmukhi, let translit = line.transliterationEn {
                Text(translit)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
            if showEnglish {
                // Bundled DB doesn't yet expose Bhai Manmohan Singh /
                // Sant Singh Khalsa columns — placeholder until the build
                // pipeline lands the augmented schema. Same situation as
                // Android; intentional v1 placeholder.
                Text("(English translation will appear here in the next data-pipeline pass.)")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.onSurfaceVariant)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focused ? Theme.surfaceVariant : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToggleChip: View {
    let label: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Theme.primary : Theme.surface)
                .foregroundColor(selected ? Theme.onPrimary : Theme.onSurface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
