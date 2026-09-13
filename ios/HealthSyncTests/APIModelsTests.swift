import Foundation
import Testing
@testable import HealthSync

struct APIModelsTests {
    private let edmonton = TimeZone(identifier: "America/Edmonton")!
    /// 2026-09-01 08:00 in Edmonton (14:00 UTC).
    private let morning = Date(timeIntervalSince1970: 1_788_271_200)

    @Test func timestampsAreLocalTimeWithAnOffset() {
        #expect(LocalTime.iso8601(morning, timeZone: edmonton) == "2026-09-01T08:00:00-06:00")
    }

    @Test func parsesServerTimestamps() throws {
        let whole = try #require(LocalTime.parse("2026-09-01T08:00:00-06:00"))
        let fractional = try #require(LocalTime.parse("2026-09-01T08:00:00.250000-06:00"))
        #expect(whole == morning)
        #expect(abs(fractional.timeIntervalSince(whole) - 0.25) < 0.0001)
        #expect(LocalTime.parse("yesterday") == nil)
    }

    @Test func daysUseTheCalendarsTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = edmonton
        // 03:00 UTC on 2 September is still the evening of 1 September in Edmonton.
        #expect(LocalTime.day(morning.addingTimeInterval(13 * 3600), calendar: calendar) == "2026-09-01")
    }

    @Test func uploadsUseSnakeCaseAndOmitMissingValues() throws {
        let upload = SampleUpload(
            uuid: UUID(), type: "sleepAnalysis", start: morning, end: morning, value: nil, unit: nil,
            category: "asleepDeep", sourceName: "Apple Watch", sourceBundle: nil, device: nil,
            metadata: ["HKTimeZone": .string("America/Edmonton")]
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.api.encode(upload)) as? [String: Any])
        #expect(object["source_name"] as? String == "Apple Watch")
        #expect(object["category"] as? String == "asleepDeep")
        #expect(object["value"] == nil)
        #expect((object["start"] as? String)?.hasPrefix("2026-09-01T") == true)
    }

    @Test func decodesAccountsFromTheServer() throws {
        let json = """
        {"id": 3, "username": "dee", "display_name": "Dee", "is_admin": false, "is_active": true,
         "time_zone": "America/Edmonton", "last_sync_at": null, "created_at": "2026-09-12T15:56:20.878824-06:00"}
        """
        let account = try JSONDecoder.api.decode(UserAccount.self, from: Data(json.utf8))
        #expect(account.displayName == "Dee")
        #expect(account.lastSyncAt == nil)
        #expect(!account.isAdmin)
    }

    @Test func serverAddressMustBeHTTPS() {
        #expect(APIClient.serverURL(from: " healthsync.sunspinner.ca/ ")?.absoluteString == "https://healthsync.sunspinner.ca")
        #expect(APIClient.serverURL(from: "http://healthsync.sunspinner.ca") == nil)
        #expect(APIClient.serverURL(from: "") == nil)
    }

    @Test func readsServerErrorMessages() {
        #expect(APIClient.errorMessage(Data(#"{"detail": "Incorrect username or password."}"#.utf8)) == "Incorrect username or password.")
        #expect(APIClient.errorMessage(Data(#"{"detail": [{"msg": "too short"}, {"msg": "bad zone"}]}"#.utf8)) == "too short\nbad zone")
        #expect(APIClient.errorMessage(Data("<html>".utf8)) == nil)
    }

    @Test func acceptedUploadsMoveTheCountsLocally() {
        let june = morning.addingTimeInterval(-90 * 24 * 3600)
        let later = morning.addingTimeInterval(60)
        var status = SyncStatus(
            lastSyncAt: nil,
            samples: [TypeCoverage(type: "stepCount", count: 10, first: morning, last: morning)],
            workoutCount: 0,
            dailySummaryCount: 0
        )

        status.recordSamples(type: "stepCount", inserted: 5, deleted: 2, first: june, last: later)
        status.recordSamples(type: "heartRate", inserted: 3, deleted: 0, first: morning, last: morning)
        // Only deletions for a type the server has no rows for: nothing to show.
        status.recordSamples(type: "bodyMass", inserted: 0, deleted: 4, first: nil, last: nil)

        #expect(status.samples.map(\.type) == ["heartRate", "stepCount"])
        #expect(status.samples[0].count == 3)
        #expect(status.samples[1].count == 13)
        #expect(status.samples[1].first == june)
        #expect(status.samples[1].last == later)
    }
}
