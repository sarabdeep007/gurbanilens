import SwiftUI

/// SwiftUI palette + typography mirroring the Android Compose theme.
/// Dark-first — most Paath / Kirtan happens early morning or evening.
/// Saffron accents (#FF9933) for primary action, deep indigo for surfaces.
public enum Palette {
    // Brand
    public static let saffron     = Color(red: 1.00, green: 0.60, blue: 0.20)      // #FF9933
    public static let saffronDark = Color(red: 0.80, green: 0.43, blue: 0.00)      // #CC6F00

    // Surfaces — dark
    public static let indigoBg    = Color(red: 0.10, green: 0.11, blue: 0.18)      // #1A1B2E
    public static let indigoLight = Color(red: 0.16, green: 0.17, blue: 0.25)      // #2A2B40
    public static let indigoMid   = Color(red: 0.23, green: 0.23, blue: 0.33)      // #3A3B55

    // Foreground
    public static let cream       = Color(red: 1.00, green: 0.965, blue: 0.898)    // #FFF6E5
    public static let indigoFg    = Color(red: 0.10, green: 0.11, blue: 0.18)      // #1A1B2E
    public static let ash         = Color(red: 0.71, green: 0.72, blue: 0.78)      // #B5B7C7
    public static let dimAsh      = Color(red: 0.42, green: 0.43, blue: 0.49)      // #6C6E7E

    // Status
    public static let success     = Color(red: 0.30, green: 0.69, blue: 0.31)      // #4CAF50
    public static let warning     = Color(red: 1.00, green: 0.70, blue: 0.00)      // #FFB300
    public static let danger      = Color(red: 0.90, green: 0.45, blue: 0.45)      // #E57373
}

/// Adaptive palette — light/dark variants per slot. SwiftUI Color blending
/// uses dynamic UIColor so a screen with `Theme.background` flips correctly
/// when the user toggles iOS dark mode.
public enum Theme {
    public static let primary: Color        = adaptive(dark: Palette.saffron,     light: Palette.saffronDark)
    public static let onPrimary: Color      = adaptive(dark: Palette.indigoFg,    light: Palette.cream)
    public static let secondary: Color      = adaptive(dark: Palette.saffronDark, light: Palette.saffron)
    public static let background: Color     = adaptive(dark: Palette.indigoBg,    light: Palette.cream)
    public static let onBackground: Color   = adaptive(dark: Palette.cream,       light: Palette.indigoFg)
    public static let surface: Color        = adaptive(dark: Palette.indigoLight, light: Palette.cream)
    public static let onSurface: Color      = adaptive(dark: Palette.cream,       light: Palette.indigoFg)
    public static let surfaceVariant: Color = adaptive(dark: Palette.indigoMid,   light: Palette.ash)
    public static let onSurfaceVariant: Color = adaptive(dark: Palette.ash,       light: Palette.dimAsh)
    public static let error: Color          = Palette.danger
    public static let success: Color        = Palette.success
    public static let warning: Color        = Palette.warning

    private static func adaptive(dark: Color, light: Color) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Apply the Theme.background as the root surface for a screen. Use on the
/// outermost container of every screen so the saffron-on-indigo identity is
/// consistent without sprinkling backgrounds across child views.
public struct ThemedBackground: ViewModifier {
    public func body(content: Content) -> some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .foregroundColor(Theme.onBackground)
        .tint(Theme.primary)
    }
}

public extension View {
    /// Wrap a screen in the GurbaniLens dark-first theme background.
    func themed() -> some View { modifier(ThemedBackground()) }
}
