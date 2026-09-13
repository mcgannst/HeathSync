import SwiftUI

struct RootView: View {
    let session: SessionStore
    let sync: SyncCoordinator

    var body: some View {
        Group {
            if let current = session.session {
                HomeView(session: session, sync: sync, current: current)
            } else {
                SignInView(session: session, sync: sync)
            }
        }
        // Health data can't be read once the iPhone locks, so keep the screen on while an upload runs.
        // Auto-lock comes back as soon as the sync finishes, fails or is cancelled.
        .onChange(of: sync.isSyncing, initial: true) { _, syncing in
            UIApplication.shared.isIdleTimerDisabled = syncing
        }
    }
}
