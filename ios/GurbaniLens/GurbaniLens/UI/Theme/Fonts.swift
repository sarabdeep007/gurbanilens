import SwiftUI
import UIKit

/// Custom font helpers for Gurmukhi rendering.
///
/// We bundle **Noto Serif Gurmukhi** (a variable font carrying the full
/// `wght` axis) under `Resources/Fonts/NotoSerifGurmukhi-Variable.ttf`,
/// registered via `UIAppFonts` in `project.yml`. SwiftUI exposes
/// variable fonts via the family name from the font file's name table;
/// for this specific font that's `"NotoSerifGurmukhi"`.
///
/// The `Font.custom(_:size:)` API silently falls back to the system
/// font when the named family isn't found — important for the first
/// run before `fetch_ios_deps.sh` has been executed, or builds without
/// the font bundled. To detect a silent fallback we log the available
/// "Noto" family names once via ``logRegisteredNotoFamilies()`` —
/// search the Xcode console for `[DIAG] Fonts.notoFamilies=…`.
public enum AppFonts {

    /// PostScript / family name the font registers under once it's
    /// installed in iOS via `UIAppFonts`. If a future build of the
    /// font changes this, the `.custom(_:)` call below silently falls
    /// back to system — log inspection via
    /// ``logRegisteredNotoFamilies()`` is how you'll spot it.
    public static let notoSerifGurmukhi = "NotoSerifGurmukhi"

    /// One-shot DIAG dump of every installed font family that contains
    /// "Noto" (case-insensitive). Call once at app start so the Xcode
    /// console makes the answer easy to find. Idempotent; subsequent
    /// calls re-log the same data.
    public static func logRegisteredNotoFamilies() {
        let matching = UIFont.familyNames
            .filter { $0.range(of: "Noto", options: .caseInsensitive) != nil }
            .sorted()
        if matching.isEmpty {
            NSLog("[DIAG] Fonts.notoFamilies=[] — Noto Serif Gurmukhi NOT registered. Run `scripts/fetch_ios_deps.sh` then re-build, or verify UIAppFonts in project.yml.")
            return
        }
        for family in matching {
            let postScriptNames = UIFont.fontNames(forFamilyName: family)
            NSLog("[DIAG] Fonts.notoFamilies family=\"\(family)\" postScriptNames=\(postScriptNames)")
        }
    }
}

public extension Font {
    /// Body Gurmukhi at `size` points. Falls back to system font when
    /// Noto Serif Gurmukhi isn't installed (typical fresh checkout
    /// before `fetch_ios_deps.sh`).
    static func notoSerifGurmukhi(_ size: CGFloat) -> Font {
        return .custom(AppFonts.notoSerifGurmukhi, size: size)
    }

    /// Weighted Gurmukhi at `size` points. For a variable font with a
    /// `wght` axis, SwiftUI's `.weight()` modifier picks the closest
    /// registered named instance. The system-font fallback honours
    /// `weight` too, so missing-font rendering still looks reasonable.
    static func notoSerifGurmukhi(_ size: CGFloat, weight: Font.Weight) -> Font {
        return .custom(AppFonts.notoSerifGurmukhi, size: size).weight(weight)
    }
}
