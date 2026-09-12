import SwiftUI

@main
struct HealthSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(session: .shared, sync: .shared)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await SessionStore.shared.refreshUser()
                    await SyncCoordinator.shared.sync()
                }
            case .background:
                BackgroundSync.shared.scheduleTasks()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Both must happen before launch finishes so iOS can wake the app for background work.
        BackgroundSync.shared.registerTasks()
        BackgroundSync.shared.startObserving()
        return true
    }
}
