import SwiftUI
import GurbaniLensCore

/// Sangat view — single matched pangti, very large font, projector-
/// friendly. Brief #8 Commit 5/7.
///
/// **Use case**: phone connected to a projector / external display in
/// the Darbar Sahib, or held up by a sevadaar so distant Sangat can
/// follow along. Layout strips everything except the single matched
/// pangti; the line is rendered at 48 pt Noto Serif Gurmukhi with
/// minimumScaleFactor 0.5 (will shrink to ~24 pt if the pangti is
/// very long) and a lineLimit of 3 (long pangtis wrap up to three
/// lines, longer than that and the scale factor steps in).
///
/// **Animation**: fade transition when `currentLineId` changes. No
/// movement — just one pangti fades out, the next fades in. Calmer
/// than the Raagi-view auto-scroll because the Sangat view is
/// designed to be read at a distance.
///
/// **Layout**: centered vertically + horizontally. Small "Ang N"
/// label at the bottom for reference.
struct SangatView: View {
    let shabad: FullShabad
    let currentLineId: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Group {
                if let line = currentLine {
                    Text(rowGurmukhi(line))
                        .font(.notoSerifGurmukhi(48, weight: .medium))
                        .foregroundColor(Theme.onSurface)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 24)
                        .id(line.id)
                        .transition(.opacity)
                } else {
                    Text("")
                }
            }
            .animation(.easeInOut(duration: 0.35), value: currentLineId)
            Spacer()
            Text(shabad.headerLabel)
                .font(.system(size: 13))
                .foregroundColor(Theme.onSurfaceVariant.opacity(0.7))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentLine: Line? {
        shabad.lines.first(where: { $0.id == currentLineId })
            ?? shabad.lines.first
    }

    private func rowGurmukhi(_ line: Line) -> String {
        if let unicode = line.gurmukhiUnicode, !unicode.isEmpty {
            return unicode
        }
        return Gurmukhi.fromAnmolLipi(line.gurmukhi)
    }
}

#if DEBUG
struct SangatView_Previews: PreviewProvider {
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
                     gurmukhi: "ਅਉਖੀ ਘੜੀ ਨ ਦੇਖਣ ਦੇਈ ਅਪਨਾ ਬਿਰਦੁ ਸਮਾਲੇ",
                     gurmukhiUnicode: "ਅਉਖੀ ਘੜੀ ਨ ਦੇਖਣ ਦੇਈ ਅਪਨਾ ਬਿਰਦੁ ਸਮਾਲੇ",
                     transliterationEn: nil, firstLetters: nil, orderId: 2),
            ]
        )
        SangatView(shabad: sample, currentLineId: "L2")
            .themed()
            .preferredColorScheme(.dark)
    }
}
#endif
