import Foundation
import Testing
@testable import HealthSync

struct SleepCalculatorTests {
    private func at(_ hour: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hour * 3600)
    }

    private func interval(_ start: Double, _ end: Double, _ stage: SleepStage) -> SleepInterval {
        SleepInterval(start: at(start), end: at(end), stage: stage)
    }

    @Test func overlappingSourcesCountOnce() {
        // An Apple Watch and an iPhone both recorded part of the same sleep.
        let summary = SleepCalculator.summarize([
            interval(0, 2, .core),
            interval(1, 3, .unspecified),
        ])
        #expect(summary.asleep == 3 * 3600)
        #expect(summary.duration(.core) == 2 * 3600)
        #expect(summary.duration(.deep) == 0)
    }

    @Test func awakeAndInBedAreNotAsleep() {
        let summary = SleepCalculator.summarize([
            interval(0, 8, .inBed),
            interval(0, 3, .core),
            interval(3, 3.5, .awake),
            interval(3.5, 6, .deep),
        ])
        #expect(summary.asleep == 5.5 * 3600)
        #expect(summary.duration(.awake) == 0.5 * 3600)
        #expect(summary.duration(.inBed) == 8 * 3600)
    }

    @Test func smallGapsStayInOneSession() {
        let sessions = SleepCalculator.sessions(
            from: [interval(0, 2, .core), interval(3, 5, .deep), interval(9, 10, .core)],
            gap: 3 * 3600
        )
        #expect(sessions.count == 2)
        #expect(sessions.first?.count == 2)
    }
}

struct NightlySleepTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Edmonton")!
        return calendar
    }()

    private func local(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private func stats(_ summaries: [DailySummary]) -> [String: DailySummary] {
        Dictionary(uniqueKeysWithValues: summaries.map { ($0.stat, $0) })
    }

    @Test func nightsAreDatedByTheDayYouWakeUp() throws {
        let summaries = NightlySleep.summaries(
            from: [
                SleepInterval(start: local(1, 23), end: local(2, 3), stage: .core),
                SleepInterval(start: local(2, 3), end: local(2, 7), stage: .deep),
            ],
            firstDay: local(1, 0),
            calendar: calendar
        )
        #expect(Set(summaries.map(\.day)) == ["2026-09-02"])
        let byStat = stats(summaries)
        let asleep = try #require(byStat["asleep"])
        let deep = try #require(byStat["deep"])
        let wake = try #require(byStat["wake_time"])
        #expect(asleep.value == 8.0)
        #expect(asleep.unit == "hr")
        #expect(deep.value == 4.0)
        #expect(wake.value == local(2, 7).timeIntervalSince1970)
        #expect(wake.unit == "unix_s")
    }

    @Test func aNapDoesNotReplaceTheNight() throws {
        let summaries = NightlySleep.summaries(
            from: [
                SleepInterval(start: local(1, 23), end: local(2, 7), stage: .core),
                SleepInterval(start: local(2, 14), end: local(2, 15), stage: .core),
            ],
            firstDay: local(1, 0),
            calendar: calendar
        )
        let asleep = try #require(stats(summaries)["asleep"])
        #expect(asleep.value == 8.0)
    }

    @Test func nightsBeforeTheFirstDayAreLeftOut() {
        let summaries = NightlySleep.summaries(
            from: [SleepInterval(start: local(1, 23), end: local(2, 7), stage: .core)],
            firstDay: local(3, 0),
            calendar: calendar
        )
        #expect(summaries.isEmpty)
    }
}
