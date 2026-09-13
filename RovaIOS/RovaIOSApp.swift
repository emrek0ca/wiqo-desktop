import SwiftUI

@main
struct RovaIOSApp: App {
    @StateObject private var model = IOSConnectionModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
