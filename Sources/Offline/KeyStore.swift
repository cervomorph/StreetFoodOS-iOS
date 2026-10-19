import Foundation
import Security

/// Keychain-backed storage for the native cache key material (P3).
///
/// Rules (binding — these mirror the web layer's model):
///   - the device key and its wraps live ONLY in the Keychain, never in
///     UserDefaults/files, never sent to the server
///   - `…ThisDeviceOnly` accessibility: no iCloud Keychain sync, no restore
///     onto a different device
///   - `AfterFirstUnlock` so a cold boot can serve cached pages before the
///     user interacts, while a device that has never been unlocked stays shut
///   - logout deletes every item; the wrapped PIN copy is deleted when the
///     user turns device protection off
enum KeyStore {

    enum StoreError: Error {
        case status(OSStatus)
        case badData
    }

    static let service = "com.cervomorph.streetfoodos.cachekey"

    enum Item: String {
        case deviceKey = "device-key"
        case pinWrap = "pin-wrap"
        case passwordWrap = "password-wrap"
        case owner = "owner"
    }

    private static func query(_ item: Item, account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account ?? item.rawValue
        ]
        return q
    }

    static func save(_ data: Data, item: Item, account: String? = nil) throws {
        var q = query(item, account: account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            q.merge(attrs) { _, new in new }
            let addStatus = SecItemAdd(q as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.status(addStatus) }
        } else if status != errSecSuccess {
            throw StoreError.status(status)
        }
    }

    static func load(item: Item, account: String? = nil) throws -> Data? {
        var q = query(item, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.status(status) }
        guard let data = out as? Data else { throw StoreError.badData }
        return data
    }

    static func delete(item: Item, account: String? = nil) throws {
        let status = SecItemDelete(query(item, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.status(status) }
    }

    static func deleteAll() throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.status(status) }
    }

    // MARK: - Typed helpers

    static func saveDeviceKey(_ key: Data) throws {
        try save(key, item: .deviceKey)
    }

    static func loadDeviceKey() throws -> Data? {
        try load(item: .deviceKey)
    }

    static func saveWrap(_ wrap: CacheCrypto.Wrapped, for item: Item = .pinWrap) throws {
        try save(try CacheCrypto.encode(wrap), item: item)
    }

    static func loadWrap(_ item: Item = .pinWrap) throws -> CacheCrypto.Wrapped? {
        guard let data = try load(item: item) else { return nil }
        return try CacheCrypto.decodeWrapped(data)
    }

    /// The account the device key belongs to (username as signed in). Used to
    /// refuse an unlock when a different user has since signed in.
    static func saveOwner(_ username: String) throws {
        try save(Data(username.utf8), item: .owner)
    }

    static func loadOwner() throws -> String? {
        guard let data = try load(item: .owner) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
