import SwiftUI

@main
struct RovaIOSApp: App {
    @StateObject private var model = IOSConnectionModel()
    @StateObject private var authSession = AuthSessionStore()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, authSession: authSession)
        }
    }
}
