import BackgroundTasks
import HealthKit
import os

private let log = Logger(subsystem: "com.mcgannst.healthsync", category: "background")

/// Wakes the app to upload: HealthKit background delivery when new samples arrive, a periodic app refresh,
/// and a longer processing task (while charging) that lets a large first upload finish overnight.
@MainActor
final class BackgroundSync {
    static let shared = BackgroundSync()
    static let refreshTaskID = "com.mcgannst.healthsync.refresh"
    static let processingTaskID = "com.mcgannst.healthsync.processing"

    private var observerQueries: [HKObserverQuery] = []

    private init() {}

    func registerTasks() {
        for identifier in [Self.refreshTaskID, Self.processingTaskID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                Task { @MainActor in
                    BackgroundSync.shared.handle(task)
                }
            }
        }
    }

    func scheduleTasks() {
        guard SessionStore.shared.session != nil else { return }

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)

        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = true

        for request in [refresh, processing] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                log.error("Couldn't schedule \(request.identifier): \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ task: BGTask) {
        scheduleTasks()
        task.expirationHandler = {
            Task { @MainActor in SyncCoordinator.shared.cancel() }
        }
        Task {
            await SyncCoordinator.shared.sync()
            task.setTaskCompleted(success: !SyncCoordinator.shared.isFailed)
        }
    }

    func startObserving() {
        guard HKHealthStore.isHealthDataAvailable(), observerQueries.isEmpty, SessionStore.shared.session != nil else {
            return
        }
        let store = Health.store
        for type in HealthMetric.observedTypes(for: SyncCoordinator.shared.enabledGroups) {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if let error {
                    log.error("Observer error for \(type.identifier): \(error.localizedDescription)")
                    completionHandler()
                    return
                }
                Task { @MainActor in
                    await SyncCoordinator.shared.sync()
                    // iOS stops background delivery for apps that don't call this.
                    completionHandler()
                }
            }
            store.execute(query)
            observerQueries.append(query)

            store.enableBackgroundDelivery(for: type, frequency: .hourly) { success, error in
                if !success {
                    log.error("Background delivery failed for \(type.identifier): \(error?.localizedDescription ?? "unknown")")
                }
            }
        }
    }

    func stopObserving() {
        observerQueries.forEach(Health.store.stop)
        observerQueries.removeAll()
        Health.store.disableAllBackgroundDelivery { _, _ in }
    }

    func restartObserving() {
        stopObserving()
        startObserving()
    }
}

private extension SyncCoordinator {
    var isFailed: Bool {
        if case .failed = status { true } else { false }
    }
}
