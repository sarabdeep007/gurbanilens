import SwiftUI

/// Overlay banner shown when JaikaraDetector matches a transcript.
/// Brief #8 Commit 3.
///
/// **Visual treatment**: a translucent saffron rounded-rectangle with
/// the jaikara text in large Noto Serif Gurmukhi. Sits above the
/// shabad content but doesn't replace it — the user can still see the
/// shabad faintly behind the banner.
///
/// **Lifecycle**: parent (RaagiModeScreen) controls visibility via
/// the engine's `@Published jaikaraBanner: String?`. When non-nil,
/// banner appears with a fade-in; auto-dismissed by the engine after
/// 3 s with a fade-out.
struct JaikaraBanner: View {
    let text: String

    private static let saffron = Color(red: 1.0, green: 0.55, blue: 0.0)

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.notoSerifGurmukhi(48, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .background(
                    Self.saffron.opacity(0.92)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                )
                .padding(.horizontal, 24)
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

#if DEBUG
struct JaikaraBanner_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                JaikaraBanner(text: "ਵਾਹਿਗੁਰੂ")
                Spacer().frame(height: 32)
                JaikaraBanner(text: "ਬੋਲੇ ਸੋ ਨਿਹਾਲ")
                Spacer().frame(height: 32)
                JaikaraBanner(text: "ਧੰਨ ਗੁਰੂ ਨਾਨਕ ਦੇਵ ਜੀ")
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
