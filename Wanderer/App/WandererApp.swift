import SwiftUI
import WandererCore

@main
struct WandererApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.signal)
        }
    }
}
