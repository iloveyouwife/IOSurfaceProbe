import Foundation
import Security

/// This-device-only backup of the pairing record, used if an app upgrade or
/// reinstallation loses its private Documents/Application Support directory.
/// Only the same keychain access group (normally the same signing team) can
/// recover it; a changed team ID or bundle ID may make it unavailable.
enum DevicePairingVault {
    private static let service = "com.cacheguard.airlift.localpairing"
    private static let account = "device-trust-record-v1"

    private static var identity: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account,
         kSecAttrSynchronizable: kCFBooleanFalse as Any]
    }

    @discardableResult
    static func save(_ record: Data) -> Bool {
        var query = identity
        query[kSecValueData] = record
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else { return false }
        return SecItemUpdate(identity as CFDictionary, [kSecValueData: record] as CFDictionary) == errSecSuccess
    }

    static func read() -> Data? {
        var query = identity
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func remove() {
        SecItemDelete(identity as CFDictionary)
    }
}
