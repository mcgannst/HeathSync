import Foundation
import Security

enum Keychain {
    private static let service = "com.mcgannst.healthsync"

    static func load<Value: Decodable>(_ type: Value.Type, account: String) -> Value? {
        data(for: account).flatMap { try? JSONDecoder.api.decode(Value.self, from: $0) }
    }

    /// Replaces the stored value; passing nil deletes it.
    static func save<Value: Encodable>(_ value: Value?, account: String) {
        set(value.flatMap { try? JSONEncoder.api.encode($0) }, for: account)
    }

    private static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func set(_ data: Data?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }

        var attributes = query
        attributes[kSecValueData as String] = data
        // Background uploads run while the device is locked, after it has been unlocked once since boot.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
