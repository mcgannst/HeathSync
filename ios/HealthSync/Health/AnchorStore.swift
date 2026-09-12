import Foundation
import HealthKit

/// How far each HealthKit type has been uploaded, so the next sync sends only what's new.
/// One file per server and account, in Application Support.
struct AnchorStore {
    private struct Stored: Codable {
        var anchors: [String: Data] = [:]
        /// Types whose full two-year daily summaries have been uploaded once.
        var summarized: Set<String> = []
    }

    private let fileURL: URL
    private var stored: Stored

    init(scope: String) {
        fileURL = Self.directory.appending(path: "anchors-\(scope).plist")
        stored = (try? Data(contentsOf: fileURL)).flatMap { try? PropertyListDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    func anchor(for key: String) -> HKQueryAnchor? {
        stored.anchors[key].flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
    }

    mutating func setAnchor(_ anchor: HKQueryAnchor, for key: String) {
        stored.anchors[key] = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        save()
    }

    func isSummarized(_ key: String) -> Bool {
        stored.summarized.contains(key)
    }

    mutating func markSummarized(_ key: String) {
        guard stored.summarized.insert(key).inserted else { return }
        save()
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Anchors", directoryHint: .isDirectory)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let data = try? PropertyListEncoder().encode(stored) else { return }
        // Readable in the background once the device has been unlocked after boot, like the Keychain session.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
