import Foundation
import CryptoKit

/// Encrypted, session-scoped page cache for the WKWebView shell (P3).
///
/// WHY: WKWebView does not run service workers, so the web layer's offline
/// cache cannot exist on iOS. The shell keeps its own copy of every rendered
/// page, encrypted at rest with the device key, and serves it when the network
/// is gone.
///
/// BINDING RULES (from the stale-auth incident — do not relitigate):
///   - never store /login, /logout, /auth/* or /api/* — a cached auth screen
///     must never resurrect a signed-out session
///   - the cache is unlocked per session and wiped on logout
///   - the device key lives in the Keychain (KeyStore); every file is sealed
///     with AES-GCM and only the ciphertext touches disk
///   - a served copy keeps its original savedAt so the UI can say how old it is
final class PageCache {

    static let shared = PageCache()

    struct Entry: Codable {
        var path: String
        var html: String
        var savedAt: Date
    }

    enum CacheError: Error {
        case locked
        case notCacheable
        case badEntry
    }

    /// Paths that must never be cached, whatever the caller asks for.
    static let deniedPrefixes = ["/login", "/logout", "/auth/", "/api/"]

    static func isCacheable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let p = path.split(separator: "?").first.map(String.init) ?? path
        for denied in deniedPrefixes where p == denied || p.hasPrefix(denied) { return false }
        return true
    }

    private let dir: URL
    private let queue = DispatchQueue(label: "com.cervomorph.streetfoodos.pagecache", qos: .utility)
    private var deviceKey: Data?

    init(directory: URL? = nil) {
        if let directory {
            dir = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            dir = base.appendingPathComponent("OfflineCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Session key

    var isUnlocked: Bool { deviceKey != nil }

    /// Unlock with the user's password or PIN. Creates the device key on first
    /// use and wraps it in the Keychain; afterwards the wrap is the only copy.
    func unlock(secret: String) throws {
        if let wrapped = try KeyStore.loadWrap(.passwordWrap) {
            deviceKey = try CacheCrypto.unwrap(wrapped, secret: secret)
            return
        }
        if let wrapped = try KeyStore.loadWrap(.pinWrap) {
            deviceKey = try CacheCrypto.unwrap(wrapped, secret: secret)
            return
        }
        // First run on this device: mint, wrap and store.
        let fresh = CacheCrypto.makeDeviceKey()
        try KeyStore.saveDeviceKey(fresh)
        try KeyStore.saveWrap(try CacheCrypto.wrap(deviceKey: fresh, secret: secret), for: .passwordWrap)
        deviceKey = fresh
    }

    /// Unlock using the device key in the Keychain, minting one on first run.
    /// (Password/PIN wraps arrive with the native lock screen.)
    func unlockWithKeychain() throws {
        if let existing = try KeyStore.loadDeviceKey() { deviceKey = existing; return }
        let fresh = CacheCrypto.makeDeviceKey()
        try KeyStore.saveDeviceKey(fresh)
        deviceKey = fresh
    }

    /// Test seam: inject a key without touching the Keychain.
    func unlock(withDeviceKey key: Data) throws {
        guard key.count == CacheCrypto.keyBytes else { throw CacheError.locked }
        deviceKey = key
    }

    func lock() { deviceKey = nil }

    // MARK: - Store

    func save(path: String, html: String, at date: Date = Date()) throws {
        guard let key = deviceKey else { throw CacheError.locked }
        guard PageCache.isCacheable(path) else { throw CacheError.notCacheable }
        let entry = Entry(path: path, html: html, savedAt: date)
        let payload = try JSONEncoder().encode(entry)
        let sealedPayload = try CacheCrypto.seal(payload, key: key)
        let blob = try JSONEncoder().encode(sealedPayload)
        let target = fileURL(for: path)
        queue.sync {
            #if os(iOS)
            try? blob.write(to: target, options: [.atomic, .completeFileProtection])
            #else
            // The macOS CI host has no file-protection API — same code path
            // minus the iOS-only option.
            try? blob.write(to: target, options: [.atomic])
            #endif
        }
    }

    func load(path: String) throws -> Entry? {
        guard let key = deviceKey else { throw CacheError.locked }
        guard PageCache.isCacheable(path) else { return nil }
        let file = fileURL(for: path)
        guard let blob = try? Data(contentsOf: file) else { return nil }
        let sealedPayload = try JSONDecoder().decode(CacheCrypto.Sealed.self, from: blob)
        let payload = try CacheCrypto.open(sealedPayload, key: key)
        guard let entry = try? JSONDecoder().decode(Entry.self, from: payload) else { throw CacheError.badEntry }
        return entry
    }

    func remove(path: String) {
        try? FileManager.default.removeItem(at: fileURL(for: path))
    }

    /// Logout: drop the key and every cached page.
    func wipe() {
        deviceKey = nil
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    func stats() -> (pages: Int, bytes: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var bytes = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            bytes += size
        }
        return (files.count, bytes)
    }

    // MARK: - Internals

    /// Snapshot format version. v2 inlines CSS and strips scripts; entries
    /// written by v1 are unreachable by design, so an upgrade forces a rewrite
    /// instead of serving an unstyled copy offline.
    static let formatVersion = 2

    private func fileURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data("v\(PageCache.formatVersion)|\(path)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + ".bin")
    }
}
