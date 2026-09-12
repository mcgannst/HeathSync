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
    let count: Int
    let first: Date
    let last: Date

    var id: String { type }
}

struct SyncStatus: Decodable, Sendable {
    let lastSyncAt: Date?
    let samples: [TypeCoverage]
    let workoutCount: Int
    let dailySummaryCount: Int
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
