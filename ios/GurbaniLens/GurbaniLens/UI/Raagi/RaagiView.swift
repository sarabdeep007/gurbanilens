import SwiftUI
import GurbaniLensCore

/// Raagi view — full shabad scrolled with the currently-matched
/// pangti highlighted. Default Raagi-Mode display per Brief #8.
///
/// **Auto-scroll**: when `currentLineId` changes, the SwiftUI
/// ScrollViewReader smoothly scrolls so the matched line sits in the
/// middle 40 % of the viewport (anchor=center). 0.3 s easeInOut
/// animation matches the highlight crossfade so visual updates feel
/// like one continuous movement.
///
/// **Highlight**: matched pangti gets a saffron-tinted rounded
/// background; non-matched lines render plain on `Theme.background`.
/// The Brief #7's tier-based confidence styling does NOT apply here —
/// Raagi Mode already gates display on score ≥ 70, so any pangti the
/// user sees is "confidently matched". The highlight is purely a
/// "this is where the raagi is right now" affordance.
///
/// **Font**: Noto Serif Gurmukhi everywhere — 20pt for non-matched
/// lines, 24pt + medium weight for the highlighted line.
struct RaagiView: View {
    let shabad: FullShabad
    let currentLineId: String

    private static let highlightTint = Color(red: 1.0, green: 0.55, blue: 0.0)
    private static let highlightTintBackground = Color(red: 1.0, green: 0.55, blue: 0.0).opacity(0.15)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(shabad.headerLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.onSurfaceVariant)
                        .padding(.leading, 4)
                        .padding(.top, 8)

                    ForEach(shabad.lines, id: \.id) { line in
                        line.id == currentLineId
                            ? AnyView(highlightedRow(line))
                            : AnyView(plainRow(line))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 120)  // breathing room above bottom
                                        // waveform / status bar
            }
            .onChange(of: currentLineId) { newId in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onAppear {
                // Initial position: jump (no animation) to the
                // matched line so we don't start at the top and slide
                // down — feels more correct when the raagi is
                // already mid-shabad.
                proxy.scrollTo(currentLineId, anchor: .center)
            }
        }
    }

    private func highlightedRow(_ line: Line) -> some View {
        Text(rowGurmukhi(line))
            .font(.notoSerifGurmukhi(24, weight: .medium))
            .foregroundColor(Theme.onSurface)
            .multilineTextAlignment(.leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Self.highlightTintBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Self.highlightTint.opacity(0.7), lineWidth: 1.5)
            )
            .id(line.id)
            .transition(.opacity)
    }

    private func plainRow(_ line: Line) -> some View {
        Text(rowGurmukhi(line))
            .font(.notoSerifGurmukhi(20))
            .foregroundColor(Theme.onSurfaceVariant.opacity(0.85))
            .multilineTextAlignment(.leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(line.id)
    }

    /// Mirrors the same rule as LiveResultsScreen / ResultsScreen
    /// rowGurmukhi: prefer Unicode column when present, else Anvaad-
    /// convert the Anmol Lipi column.
    private func rowGurmukhi(_ line: Line) -> String {
        if let unicode = line.gurmukhiUnicode, !unicode.isEmpty {
            return unicode
        }
        return Gurmukhi.fromAnmolLipi(line.gurmukhi)
    }
}

#if DEBUG
struct RaagiView_Previews: PreviewProvider {
    static var previews: some View {
        let sample = FullShabad(
            id: "demo",
            lines: [
                Line(id: "L1", shabadId: "demo", ang: 1, pangti: 1,
                     lineType: "Pankti",
                     gurmukhi: "ਏਕ ਓਅੰਕਾਰ ਸਤਿ ਨਾਮੁ",
                     gurmukhiUnicode: "ੴ ਸਤਿ ਨਾਮੁ ਕਰਤਾ ਪੁਰਖੁ",
                     transliterationEn: nil, firstLetters: nil, orderId: 1),
                Line(id: "L2", shabadId: "demo", ang: 1, pangti: 2,
                     lineType: "Pankti",
                     gurmukhi: "ਨਿਰਭਉ ਨਿਰਵੈਰੁ ਅਕਾਲ ਮੂਰਤਿ",
                     gurmukhiUnicode: "ਨਿਰਭਉ ਨਿਰਵੈਰੁ ਅਕਾਲ ਮੂਰਤਿ",
                     transliterationEn: nil, firstLetters: nil, orderId: 2),
                Line(id: "L3", shabadId: "demo", ang: 1, pangti: 3,
                     lineType: "Pankti",
                     gurmukhi: "ਅਜੂਨੀ ਸੈਭੰ ਗੁਰ ਪ੍ਰਸਾਦਿ",
                     gurmukhiUnicode: "ਅਜੂਨੀ ਸੈਭੰ ਗੁਰ ਪ੍ਰਸਾਦਿ",
                     transliterationEn: nil, firstLetters: nil, orderId: 3),
            ]
        )
        RaagiView(shabad: sample, currentLineId: "L2")
            .themed()
            .preferredColorScheme(.dark)
    }
}
#endif
