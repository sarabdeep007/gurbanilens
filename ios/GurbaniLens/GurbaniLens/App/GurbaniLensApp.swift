import SwiftUI

@main
struct GurbaniLensApp: App {
    @StateObject private var container = AppContainer()

    init() {
        // One-shot DIAG dump of installed Noto* font families. Lets us
        // verify the bundled Noto Serif Gurmukhi registered correctly
        // (and exposes the family name SwiftUI Font.custom needs) from
        // the Xcode console — no extra build needed to inspect.
        AppFonts.logRegisteredNotoFamilies()
    }

    var body: some Scene {
        WindowGroup {
            AppNavGraph(container: container)
        }
    }
}
