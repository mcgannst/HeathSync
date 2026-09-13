import Foundation

// Request and response bodies for the HealthSync server (server/app/api/schemas.py).
// Keys are converted to snake_case by JSONEncoder.api / JSONDecoder.api.

struct UserAccount: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let username: String
    var displayName: String
    var isAdmin: Bool
    var isActive: Bool
    let timeZone: String
    let lastSyncAt: Date?
    let createdAt: Date
}

struct LoginRequest: Encodable {
    let username: String
    let password: String
    let deviceName: String
}

struct LoginResponse: Decodable {
    let token: String
    let user: UserAccount
}

enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value): try value.encode(to: encoder)
        case let .number(value): try value.encode(to: encoder)
        case let .bool(value): try value.encode(to: encoder)
        }
    }
}

struct SampleUpload: Encodable, Sendable {
    let uuid: UUID
    let type: String
    let start: Date
    let end: Date
    let value: Double?
    let unit: String?
    let category: String?
    let sourceName: String?
    let sourceBundle: String?
    let device: String?
    let metadata: [String: JSONValue]?
}

struct SamplesUpload: Encodable, Sendable {
    let samples: [SampleUpload]
    let deleted: [UUID]
}

struct WorkoutUpload: Encodable, Sendable {
    let uuid: UUID
    let activityType: String
    let start: Date
    let end: Date
    let durationS: Double
    let activeEnergyKcal: Double?
    let distanceM: Double?
    let sourceName: String?
    let device: String?
    let metadata: [String: JSONValue]?
}

struct WorkoutsUpload: Encodable, Sendable {
    let workouts: [WorkoutUpload]
    let deleted: [UUID]
}

struct DailySummary: Encodable, Hashable, Sendable {
    let day: String
    let metric: String
    let stat: String
    let value: Double
    let unit: String
}

struct DailyUpload: Encodable, Sendable {
    let timeZone: String
    let summaries: [DailySummary]
}

struct UploadResult: Decodable, Sendable {
    let received: Int
    let inserted: Int
    let deleted: Int
}

struct TypeCoverage: Decodable, Identifiable, Sendable {
    let type: String
    var count: Int
    var first: Date
    var last: Date

    var id: String { type }
}

struct SyncStatus: Decodable, Sendable {
    let lastSyncAt: Date?
    var samples: [TypeCoverage]
    var workoutCount: Int
    let dailySummaryCount: Int
}

extension SyncStatus {
    /// Applies a page of readings the server accepted, so counts move during an upload without another request.
    /// `inserted` and `deleted` are the server's row counts, which already exclude duplicates.
    mutating func recordSamples(type: String, inserted: Int, deleted: Int, first: Date?, last: Date?) {
        if let index = samples.firstIndex(where: { $0.type == type }) {
            samples[index].count = max(0, samples[index].count + inserted - deleted)
            if let first { samples[index].first = min(samples[index].first, first) }
            if let last { samples[index].last = max(samples[index].last, last) }
        } else if inserted > 0, let first, let last {
            samples.append(TypeCoverage(type: type, count: inserted, first: first, last: last))
            samples.sort { $0.type < $1.type }
        }
    }
}

struct NewAccount: Encodable {
    let username: String
    let displayName: String
    let password: String
    let isAdmin: Bool
}

/// Only the fields that are set are sent.
struct AccountChanges: Encodable {
    var displayName: String? = nil
    var password: String? = nil
    var isActive: Bool? = nil
    var isAdmin: Bool? = nil
}
