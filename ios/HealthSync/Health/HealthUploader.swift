import HealthKit
import os

private let log = Logger(subsystem: "com.mcgannst.healthsync", category: "upload")

struct SyncReport: Sendable {
    var samplesUploaded = 0
    var samplesDeleted = 0
    var workoutsUploaded = 0
    var summariesUploaded = 0
}

/// Uploads Health data to the server.
///
/// Each type is read with an anchored query in pages, so the first run backfills two years and later runs send
/// only new samples and deletions. The anchor is saved after the server accepts each page, so an interrupted
/// upload resumes where it stopped. Daily statistics come from HealthKit's statistics queries, which
/// de-duplicate overlapping iPhone and Apple Watch samples, and are recomputed for the days that changed.
actor HealthUploader {
    static let backfillYears = 2
    private static let samplePageSize = 2000
    private static let workoutPageSize = 500
    private static let summaryBatchSize = 5000

    private let store: HKHealthStore
    private let api: APIClient
    private var anchors: AnchorStore
    private let calendar = Calendar.current

    init(store: HKHealthStore, api: APIClient, anchorScope: String) {
        self.store = store
        self.api = api
        anchors = AnchorStore(scope: anchorScope)
    }

    func run(groups: Set<DataGroup>, progress: @escaping @Sendable (String) -> Void) async throws -> SyncReport {
        var report = SyncReport()
        let today = calendar.startOfDay(for: .now)
        let backfillStart = calendar.date(byAdding: .year, value: -Self.backfillYears, to: today) ?? today

        // Keeps the server's idea of "a day" in step with this iPhone's time zone.
        _ = try await api.uploadDaily(DailyUpload(timeZone: TimeZone.current.identifier, summaries: []))

        for metric in HealthMetric.all where groups.contains(metric.group) {
            try Task.checkCancellation()
            try await upload(metric, since: backfillStart, report: &report, progress: progress)
        }
        if groups.contains(.workouts) {
            try Task.checkCancellation()
            try await uploadWorkouts(since: backfillStart, report: &report, progress: progress)
        }
        log.info("Uploaded \(report.samplesUploaded) samples, \(report.workoutsUploaded) workouts, \(report.summariesUploaded) daily summaries")
        return report
    }

    // MARK: Samples

    private func upload(
        _ metric: HealthMetric, since backfillStart: Date, report: inout SyncReport, progress: @Sendable (String) -> Void
    ) async throws {
        let predicate = HKQuery.predicateForSamples(withStart: backfillStart, end: nil)
        var changedDays = Set<Date>()
        var sawDeletion = false
        var uploaded = 0

        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(
                predicates: [.sample(type: metric.sampleType, predicate: predicate)],
                anchor: anchors.anchor(for: metric.name),
                limit: Self.samplePageSize
            )
            let page = try await query.result(for: store)
            let samples = page.addedSamples.compactMap { SampleUpload($0, metric: metric) }
            let deleted = page.deletedObjects.map(\.uuid)

            if !samples.isEmpty || !deleted.isEmpty {
                let result = try await api.uploadSamples(SamplesUpload(samples: samples, deleted: deleted))
                report.samplesUploaded += result.inserted
                report.samplesDeleted += result.deleted
                uploaded += samples.count
                if uploaded >= Self.samplePageSize {
                    progress("Uploading \(metric.title.lowercased()): \(uploaded.formatted()) readings")
                }
            }
            for sample in page.addedSamples {
                changedDays.insert(calendar.startOfDay(for: sample.startDate))
                changedDays.insert(calendar.startOfDay(for: sample.endDate))
            }
            sawDeletion = sawDeletion || !deleted.isEmpty
            anchors.setAnchor(page.newAnchor, for: metric.name)

            if page.addedSamples.count < Self.samplePageSize && page.deletedObjects.count < Self.samplePageSize {
                break
            }
        }

        try await uploadSummaries(
            for: metric, changedDays: changedDays, sawDeletion: sawDeletion, backfillStart: backfillStart, report: &report
        )
    }

    // MARK: Daily summaries

    private func uploadSummaries(
        for metric: HealthMetric, changedDays: Set<Date>, sawDeletion: Bool, backfillStart: Date, report: inout SyncReport
    ) async throws {
        guard metric.kind != .category else { return }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)) ?? .now
        let firstDay: Date
        if !anchors.isSummarized(metric.name) {
            firstDay = backfillStart
        } else if let earliest = changedDays.min() {
            // A deletion doesn't say which day it belonged to; yesterday and today cover the usual edit.
            firstDay = max(sawDeletion ? min(earliest, yesterday) : earliest, backfillStart)
        } else if sawDeletion {
            firstDay = yesterday
        } else {
            return
        }

        let summaries = try await dailySummaries(for: metric, from: firstDay, to: .now)
        for batch in summaries.chunked(Self.summaryBatchSize) {
            let result = try await api.uploadDaily(DailyUpload(timeZone: TimeZone.current.identifier, summaries: batch))
            report.summariesUploaded += result.inserted
        }
        anchors.markSummarized(metric.name)
    }

    private func dailySummaries(for metric: HealthMetric, from start: Date, to end: Date) async throws -> [DailySummary] {
        switch metric.kind {
        case .cumulative, .discrete: try await statistics(for: metric, from: start, to: end)
        case .sleep: try await sleepSummaries(from: start, to: end)
        case .duration: try await durationSummaries(for: metric, from: start, to: end)
        case .category: []
        }
    }

    private func statistics(for metric: HealthMetric, from start: Date, to end: Date) async throws -> [DailySummary] {
        guard case let .quantity(identifier) = metric.typeID, let unit = metric.hkUnit, let unitLabel = metric.unit else {
            return []
        }
        let cumulative = metric.kind == .cumulative
        let dayStart = calendar.startOfDay(for: start)
        let query = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(identifier), predicate: HKQuery.predicateForSamples(withStart: dayStart, end: end)
            ),
            options: cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax, .mostRecent],
            anchorDate: dayStart,
            intervalComponents: DateComponents(day: 1)
        )

        let collection: HKStatisticsCollection
        do {
            collection = try await query.result(for: store)
        } catch let error as HKError where error.code == .errorNoData {
            return []
        }

        let calendar = calendar
        return collection.statistics().flatMap { statistics -> [DailySummary] in
            let day = LocalTime.day(statistics.startDate, calendar: calendar)
            let values: [(String, HKQuantity?)] = cumulative
                ? [("sum", statistics.sumQuantity())]
                : [
                    ("avg", statistics.averageQuantity()),
                    ("min", statistics.minimumQuantity()),
                    ("max", statistics.maximumQuantity()),
                    ("latest", statistics.mostRecentQuantity()),
                ]
            return values.compactMap { stat, quantity in
                quantity.map {
                    DailySummary(day: day, metric: metric.name, stat: stat, value: $0.doubleValue(for: unit) * metric.scale, unit: unitLabel)
                }
            }
        }
    }

    private func sleepSummaries(from start: Date, to end: Date) async throws -> [DailySummary] {
        let firstDay = calendar.startOfDay(for: start)
        // A night that ends on the first day started the evening before.
        let predicate = HKQuery.predicateForSamples(withStart: firstDay.addingTimeInterval(-24 * 3600), end: end)
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let intervals = try await query.result(for: store).compactMap(SleepInterval.init(sample:))
        return NightlySleep.summaries(from: intervals, firstDay: firstDay, calendar: calendar)
    }

    private func durationSummaries(for metric: HealthMetric, from start: Date, to end: Date) async throws -> [DailySummary] {
        guard case let .category(identifier) = metric.typeID else { return [] }
        let firstDay = calendar.startOfDay(for: start)
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(identifier), predicate: HKQuery.predicateForSamples(withStart: firstDay, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        var minutes: [Date: Double] = [:]
        for sample in try await query.result(for: store) {
            minutes[calendar.startOfDay(for: sample.startDate), default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        return minutes.sorted { $0.key < $1.key }.map { entry in
            DailySummary(
                day: LocalTime.day(entry.key, calendar: calendar), metric: metric.name, stat: "sum",
                value: (entry.value * 10).rounded() / 10, unit: "min"
            )
        }
    }

    // MARK: Workouts

    private func uploadWorkouts(
        since backfillStart: Date, report: inout SyncReport, progress: @Sendable (String) -> Void
    ) async throws {
        let key = "workouts"
        let predicate = HKQuery.predicateForSamples(withStart: backfillStart, end: nil)
        while true {
            try Task.checkCancellation()
            let query = HKAnchoredObjectQueryDescriptor(
                predicates: [.workout(predicate)],
                anchor: anchors.anchor(for: key),
                limit: Self.workoutPageSize
            )
            let page = try await query.result(for: store)
            let workouts = page.addedSamples.map(WorkoutUpload.init)
            let deleted = page.deletedObjects.map(\.uuid)
            if !workouts.isEmpty || !deleted.isEmpty {
                if workouts.count == Self.workoutPageSize {
                    progress("Uploading workouts")
                }
                let result = try await api.uploadWorkouts(WorkoutsUpload(workouts: workouts, deleted: deleted))
                report.workoutsUploaded += result.inserted
            }
            anchors.setAnchor(page.newAnchor, for: key)
            if page.addedSamples.count < Self.workoutPageSize && page.deletedObjects.count < Self.workoutPageSize {
                break
            }
        }
    }
}

// MARK: - HealthKit to upload models

private extension SampleUpload {
    init?(_ sample: HKSample, metric: HealthMetric) {
        var value: Double?
        var unit: String?
        var category: String?
        if let quantitySample = sample as? HKQuantitySample {
            guard let hkUnit = metric.hkUnit, quantitySample.quantity.is(compatibleWith: hkUnit) else { return nil }
            value = quantitySample.quantity.doubleValue(for: hkUnit) * metric.scale
            unit = metric.unit
        } else if let categorySample = sample as? HKCategorySample {
            category = metric.categoryLabel(categorySample.value)
        } else {
            return nil
        }
        self.init(
            uuid: sample.uuid,
            type: metric.name,
            start: sample.startDate,
            end: sample.endDate,
            value: value,
            unit: unit,
            category: category,
            sourceName: sample.sourceRevision.source.name,
            sourceBundle: sample.sourceRevision.source.bundleIdentifier,
            device: sample.device?.name,
            metadata: JSONValue.metadata(sample.metadata)
        )
    }
}

private extension WorkoutUpload {
    init(_ workout: HKWorkout) {
        let distanceTypes: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports,
        ]
        self.init(
            uuid: workout.uuid,
            activityType: workout.workoutActivityType.name,
            start: workout.startDate,
            end: workout.endDate,
            durationS: workout.duration,
            activeEnergyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            distanceM: distanceTypes.lazy
                .compactMap { workout.statistics(for: HKQuantityType($0))?.sumQuantity()?.doubleValue(for: .meter()) }
                .first,
            sourceName: workout.sourceRevision.source.name,
            device: workout.device?.name,
            metadata: JSONValue.metadata(workout.metadata)
        )
    }
}

private extension SleepInterval {
    init?(sample: HKCategorySample) {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return nil }
        let stage: SleepStage
        switch value {
        case .inBed: stage = .inBed
        case .awake: stage = .awake
        case .asleepCore: stage = .core
        case .asleepDeep: stage = .deep
        case .asleepREM: stage = .rem
        case .asleepUnspecified: stage = .unspecified
        @unknown default: return nil
        }
        self.init(start: sample.startDate, end: sample.endDate, stage: stage)
    }
}

extension JSONValue {
    /// HealthKit metadata values that have a JSON form; anything else is dropped.
    static func metadata(_ metadata: [String: Any]?) -> [String: JSONValue]? {
        guard let metadata, !metadata.isEmpty else { return nil }
        var values: [String: JSONValue] = [:]
        for (key, value) in metadata {
            switch value {
            case let string as String: values[key] = .string(string)
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): values[key] = .bool(number.boolValue)
            case let number as NSNumber: values[key] = .number(number.doubleValue)
            case let date as Date: values[key] = .string(LocalTime.iso8601(date))
            case let quantity as HKQuantity: values[key] = .string(quantity.description)
            default: continue
            }
        }
        return values.isEmpty ? nil : values
    }
}
