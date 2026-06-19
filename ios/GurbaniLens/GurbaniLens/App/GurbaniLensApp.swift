import SwiftUI

@main
struct GurbaniLensApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            AppNavGraph(container: container)
        }
    }
}
