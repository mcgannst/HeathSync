import HealthKit
import Observation
import os

private let log = Logger(subsystem: "com.mcgannst.healthsync", category: "sync")

enum Health {
    static let store = HKHealthStore()
}

@MainActor
@Observable
final class SyncCoordinator {
    enum Status: Equatable {
        case idle
        case syncing(String)
        case succeeded
        case failed(String)
    }

    static let shared = SyncCoordinator()

    private(set) var status: Status = .idle
    private(set) var lastSync: Date?
    private(set) var serverStatus: SyncStatus?
    private(set) var enabledGroups: Set<DataGroup>

    var isSyncing: Bool {
        if case .syncing = status { true } else { false }
    }

    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    private static let enabledGroupsKey = "enabledGroups"
    private static let lastSyncKey = "lastSync"

    private init() {
        let stored = defaults.stringArray(forKey: Self.enabledGroupsKey)?.compactMap(DataGroup.init(rawValue:))
        enabledGroups = Set(stored ?? DataGroup.allCases)
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    func startAfterSignIn() async {
        await requestHealthAccess()
        BackgroundSync.shared.startObserving()
        await sync()
    }

    func requestHealthAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .failed("Health data isn't available on this device.")
            return
        }
        do {
            try await Health.store.requestAuthorization(toShare: [], read: HealthMetric.readTypes(for: enabledGroups))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func setGroup(_ group: DataGroup, enabled: Bool) {
        if enabled {
            enabledGroups.insert(group)
        } else {
            enabledGroups.remove(group)
        }
        defaults.set(enabledGroups.map(\.rawValue), forKey: Self.enabledGroupsKey)
        BackgroundSync.shared.restartObserving()
        if enabled {
            Task {
                await requestHealthAccess()
                await sync()
            }
        }
    }

    /// Safe to call often: calls made while a sync is running wait for it and trigger one more pass.
    func sync() async {
        guard SessionStore.shared.session != nil else { return }
        if let inFlight {
            rerunRequested = true
            await inFlight.value
            return
        }
        let task = Task {
            repeat {
                rerunRequested = false
                await performSync()
            } while rerunRequested && !Task.isCancelled
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    func cancel() {
        inFlight?.cancel()
    }

    func refreshServerStatus() async {
        guard let session = SessionStore.shared.session else { return }
        if let status = try? await session.api.status() {
            serverStatus = status
        }
    }

    /// Called on sign-out: forgets upload progress so the next account starts fresh.
    func reset() {
        inFlight?.cancel()
        BackgroundSync.shared.stopObserving()
        AnchorStore.removeAll()
        status = .idle
        lastSync = nil
        serverStatus = nil
        defaults.removeObject(forKey: Self.lastSyncKey)
    }

    private func performSync() async {
        guard let session = SessionStore.shared.session else { return }
        status = .syncing("Checking for new Health data…")
        let uploader = HealthUploader(store: Health.store, api: session.api, anchorScope: session.anchorScope)

        do {
            _ = try await uploader.run(groups: enabledGroups) { message in
                Task { @MainActor in
                    let coordinator = SyncCoordinator.shared
                    if coordinator.isSyncing {
                        coordinator.status = .syncing(message)
                    }
                }
            }
            lastSync = .now
            defaults.set(lastSync, forKey: Self.lastSyncKey)
            status = .succeeded
            await refreshServerStatus()
        } catch APIError.unauthorized {
            SessionStore.shared.sessionEnded()
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            status = .failed("Health data is locked. Unlock your iPhone to finish uploading.")
        } catch is CancellationError {
            status = .idle
        } catch {
            log.error("Sync failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }
}
