import Foundation

/// Native app lock (P3) — PIN protection for the cached, encrypted pages.
///
/// MODEL (mirrors the web's soft lock):
///   - the device key exists ONLY as a PIN wrap in the Keychain; no plaintext
///     key is stored anywhere, so a locked app cannot be read without the PIN
///   - unlocking derives the key into memory for this session (PageCache)
///   - five wrong PINs trigger a cool-off that doubles up to five minutes
///   - "forgot PIN" wipes the cache and protection — the user signs in again
///   - the app relocks after five minutes in the background
final class AppLock {

    static let shared = AppLock()

    static let backgroundLockAfter: TimeInterval = 5 * 60

    private let attemptsKey = "sfos.lock.failedAttempts"
    private let lockUntilKey = "sfos.lock.lockedUntil"
    private let defaults = UserDefaults.standard

    var hasPin: Bool { (try? KeyStore.loadWrap(.pinWrap)) != nil }

    var lockedUntil: Date? {
        let stamp = defaults.double(forKey: lockUntilKey)
        guard stamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stamp)
        return date > Date() ? date : nil
    }

    var failedAttempts: Int { defaults.integer(forKey: attemptsKey) }

    /// First run / re-protect: mint a key, wrap it under the PIN, drop any
    /// plaintext copy, and unlock the cache for this session.
    func setPin(_ pin: String) throws {
        let key = CacheCrypto.makeDeviceKey()
        let wrap = try CacheCrypto.wrap(deviceKey: key, secret: pin)
        try KeyStore.saveWrap(wrap, for: .pinWrap)
        // Keep a device-protected copy so the cache can unlock silently. The
        // PIN stays the recovery path; prompting on every launch was the thing
        // Kit objected to.
        try? KeyStore.saveDeviceKey(key)
        try KeyStore.saveOwner("device")
        try PageCache.shared.unlock(withDeviceKey: key)
        defaults.removeObject(forKey: attemptsKey)
        defaults.removeObject(forKey: lockUntilKey)
    }

    /// Unlock with the Keychain-held device key — no UI. Returns false when
    /// there is no key (fresh install, wiped, or a different user).
    @discardableResult
    func silentUnlock() -> Bool {
        guard let key = try? KeyStore.loadDeviceKey(), let key else { return false }
        do {
            try PageCache.shared.unlock(withDeviceKey: key)
            return PageCache.shared.isUnlocked
        } catch {
            NSLog("SFOS_LOCK silent unlock failed: %@", String(describing: error))
            return false
        }
    }

    /// Returns true on success; false on a wrong PIN (attempts recorded).
    /// Throws when the app is in a cool-off window.
    func unlock(pin: String) throws -> Bool {
        if let until = lockedUntil {
            let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            throw NSError(domain: "sfos.lock", code: 423, userInfo: [
                NSLocalizedDescriptionKey: "Too many attempts — try again in \(seconds)s"
            ])
        }
        guard let wrap = try KeyStore.loadWrap(.pinWrap) else { return false }
        do {
            let key = try CacheCrypto.unwrap(wrap, secret: pin)
            try PageCache.shared.unlock(withDeviceKey: key)
            defaults.removeObject(forKey: attemptsKey)
            return true
        } catch {
            let fails = failedAttempts + 1
            defaults.set(fails, forKey: attemptsKey)
            if fails >= 5 {
                let delay = min(300, 30 * Double(fails - 4))
                defaults.set(Date().addingTimeInterval(delay).timeIntervalSince1970, forKey: lockUntilKey)
            }
            return false
        }
    }

    /// Forgot the PIN: the encrypted pages are unrecoverable without it.
    func reset() {
        try? KeyStore.delete(item: .pinWrap)
        try? KeyStore.delete(item: .deviceKey)
        PageCache.shared.wipe()
        defaults.removeObject(forKey: attemptsKey)
        defaults.removeObject(forKey: lockUntilKey)
    }

    func lock() {
        PageCache.shared.lock()
    }
}
