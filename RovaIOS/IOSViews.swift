import SwiftUI

struct RootView: View {
    @ObservedObject var model: IOSConnectionModel
    @ObservedObject var authSession: AuthSessionStore

    var body: some View {
        Group {
            if !authSession.isAuthenticated {
                AuthView { authSession.refresh() }
            } else {
                // Chatting with Wiqo never requires a paired Mac - exactly like asking ChatGPT or
                // Gemini a question. Pairing only gates the Mac-specific tools themselves; a
                // device action without a paired Mac simply fails with a clear message instead of
                // blocking the whole app upfront.
                WiqoHomeView(model: model, authSession: authSession)
            }
        }
        .tint(RovaDesign.ink)
        .wiqoToastHost()
        .onChange(of: authSession.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                model.sendBackendTokenIfAvailable()
            } else {
                // A signed-out account must never leave its paired Mac (or anything else
                // device-scoped) reachable to whoever signs in next on this phone - covers every
                // sign-out path (menu button, an expired-token auto sign-out) from one place.
                model.forgetPairing()
            }
        }
        .task {
            // AuthSessionStore can start already authenticated after restoring the saved
            // account. In that case onChange does not fire, so give the paired Mac its current
            // backend session here as well; this is what keeps relay control available after an
            // app or network restart.
            if authSession.isAuthenticated {
                model.sendBackendTokenIfAvailable()
            }
        }
    }
}
