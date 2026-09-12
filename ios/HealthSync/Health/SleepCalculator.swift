import Foundation

enum SleepStage: String, CaseIterable {
    case inBed, awake, core, deep, rem, unspecified

    var isAsleep: Bool {
        switch self {
        case .core, .deep, .rem, .unspecified: true
        case .inBed, .awake: false
        }
    }
}

struct SleepInterval: Equatable {
    let start: Date
    let end: Date
    let stage: SleepStage
}

struct SleepSummary: Equatable {
    let start: Date
    let end: Date
    let asleep: TimeInterval
    let durations: [SleepStage: TimeInterval]

    func duration(_ stage: SleepStage) -> TimeInterval {
        durations[stage] ?? 0
    }
}

/// Turns raw sleep samples into session totals. Kept free of HealthKit so it can be unit tested.
enum SleepCalculator {
    /// Groups intervals into sessions separated by more than `gap` with no samples.
    static func sessions(from intervals: [SleepInterval], gap: TimeInterval) -> [[SleepInterval]] {
        var sessions: [[SleepInterval]] = []
        var sessionEnd = Date.distantPast
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if sessions.isEmpty || interval.start.timeIntervalSince(sessionEnd) > gap {
                sessions.append([interval])
                sessionEnd = interval.end
            } else {
                sessions[sessions.count - 1].append(interval)
                sessionEnd = max(sessionEnd, interval.end)
            }
        }
        return sessions
    }

    static func summarize(_ session: [SleepInterval]) -> SleepSummary {
        var durations: [SleepStage: TimeInterval] = [:]
        for stage in SleepStage.allCases {
            durations[stage] = unionDuration(session.filter { $0.stage == stage })
        }
        return SleepSummary(
            start: session.map(\.start).min() ?? .distantPast,
            end: session.map(\.end).max() ?? .distantPast,
            asleep: unionDuration(session.filter { $0.stage.isAsleep }),
            durations: durations
        )
    }

    /// Total time covered by the intervals. Overlaps count once, since an Apple Watch
    /// and an iPhone can both record the same night.
    static func unionDuration(_ intervals: [SleepInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (start: Date, end: Date)?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let range = current, interval.start <= range.end {
                current = (range.start, max(range.end, interval.end))
            } else {
                if let range = current {
                    total += range.end.timeIntervalSince(range.start)
                }
                current = (interval.start, interval.end)
            }
        }
        if let range = current {
            total += range.end.timeIntervalSince(range.start)
        }
        return total
    }
}

/// Daily sleep summaries for the server, one night per day.
enum NightlySleep {
    static let metric = "sleepAnalysis"

    /// Each night is dated by the day the person woke up. When several sessions end on the same day,
    /// the one with the most sleep wins, so an afternoon nap doesn't replace the night.
    static func summaries(
        from intervals: [SleepInterval],
        firstDay: Date,
        calendar: Calendar = .current,
        sessionGap: TimeInterval = 3 * 3600
    ) -> [DailySummary] {
        var nights: [Date: SleepSummary] = [:]
        for session in SleepCalculator.sessions(from: intervals, gap: sessionGap).map(SleepCalculator.summarize) {
            let wakeDay = calendar.startOfDay(for: session.end)
            guard wakeDay >= firstDay else { continue }
            if let existing = nights[wakeDay], existing.asleep >= session.asleep { continue }
            nights[wakeDay] = session
        }

        return nights.sorted { $0.key < $1.key }.flatMap { entry -> [DailySummary] in
            let day = LocalTime.day(entry.key, calendar: calendar)
            let night = entry.value
            func hours(_ stat: String, _ seconds: TimeInterval) -> DailySummary {
                DailySummary(day: day, metric: metric, stat: stat, value: (seconds / 36).rounded() / 100, unit: "hr")
            }
            return [
                hours("asleep", night.asleep),
                hours("core", night.duration(.core)),
                hours("deep", night.duration(.deep)),
                hours("rem", night.duration(.rem)),
                hours("unspecified", night.duration(.unspecified)),
                hours("awake", night.duration(.awake)),
                hours("in_bed", night.duration(.inBed)),
                DailySummary(day: day, metric: metric, stat: "bedtime", value: night.start.timeIntervalSince1970.rounded(), unit: "unix_s"),
                DailySummary(day: day, metric: metric, stat: "wake_time", value: night.end.timeIntervalSince1970.rounded(), unit: "unix_s"),
            ]
        }
    }
}
