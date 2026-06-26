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
    ///
    /// Brief #7.1 (2026-06-26): also dumps the bundle-resource path
    /// resolution for the font file. If the file isn't found, the
    /// fix is usually one of:
    ///   - run `scripts/fetch_ios_deps.sh` to download the font
    ///   - re-run `xcodegen generate` so the project picks it up
    ///   - verify `UIAppFonts` in project.yml points at the right
    ///     bundle path (no Fonts/ prefix — XcodeGen flattens
    ///     group references to the bundle root)
    public static func logRegisteredNotoFamilies() {
        // 1. Resource-existence probe — direct Bundle lookup.
        let resourceCandidates: [(String, String)] = [
            ("NotoSerifGurmukhi-Variable", "ttf"),
            ("NotoSerifGurmukhi[wght]", "ttf"),
        ]
        var firstFound: URL?
        for (name, ext) in resourceCandidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                NSLog("[DIAG] Fonts.bundleProbe FOUND name=\"\(name).\(ext)\" path=\(url.path)")
                if firstFound == nil { firstFound = url }
            } else {
                NSLog("[DIAG] Fonts.bundleProbe MISSING name=\"\(name).\(ext)\"")
            }
        }

        // 2. Registered-family scan.
        let matching = UIFont.familyNames
            .filter { $0.range(of: "Noto", options: .caseInsensitive) != nil }
            .sorted()
        if matching.isEmpty {
            NSLog("[DIAG] Fonts.notoFamilies=[] — Noto Serif Gurmukhi NOT registered. Bundle probe above shows whether the file is even in the .app. If MISSING: run scripts/fetch_ios_deps.sh + xcodegen generate. If FOUND but not registered: UIAppFonts entry in project.yml has the wrong path.")
        } else {
            for family in matching {
                let postScriptNames = UIFont.fontNames(forFamilyName: family)
                NSLog("[DIAG] Fonts.notoFamilies family=\"\(family)\" postScriptNames=\(postScriptNames)")
            }
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
