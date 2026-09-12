import SwiftUI

struct RootView: View {
    let session: SessionStore
    let sync: SyncCoordinator

    var body: some View {
        if let current = session.session {
            HomeView(session: session, sync: sync, current: current)
        } else {
            SignInView(session: session, sync: sync)
        }
    }
}
