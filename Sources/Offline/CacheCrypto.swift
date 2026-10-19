import Foundation
import CryptoKit

/// Cache encryption primitives for the native page cache (P3).
///
/// Mirrors the web layer's data-protection semantics so both shells speak the
/// same format:
///   - a 32-byte random device key encrypts cached pages/data
///   - the key is wrapped (AES-GCM) under a PBKDF2-SHA256 key derived from the
///     user's password or PIN, 100k iterations
///   - sealed payloads serialise as `{"v":1,"iv":"…","ct":"…"}` (base64), the
///     same shape `public/js/offline-crypto.js` produces on the web
///
/// Nothing here touches the network or disk — storage lives in KeyStore.swift.
enum CacheCrypto {

    static let version = 1
    static let kdfName = "hkdf-sha256"
    static let keyBytes = 32
    static let saltBytes = 16
    static let nonceBytes = 12

    struct Sealed: Codable, Equatable {
        var v: Int
        var iv: String
        var ct: String
    }

    struct Wrapped: Codable, Equatable {
        var salt: String
        var kdf: String
        var v: Int
        var iv: String
        var ct: String
    }

    enum CryptoError: Error {
        case badKey
        case badPayload
        case deriveFailed
        case sealFailed
    }

    // MARK: - Device key

    static func makeDeviceKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: keyBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system RNG unavailable")
        return Data(bytes)
    }

    static func makeSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system RNG unavailable")
        return Data(bytes)
    }

    // MARK: - Key derivation (PBKDF2-SHA256)

    static func deriveKey(secret: String, salt: Data) throws -> SymmetricKey {
        guard let secretData = secret.data(using: .utf8), !secretData.isEmpty else { throw CryptoError.deriveFailed }
        // Pre-hash so any secret length is accepted, then HKDF-SHA256 (CryptoKit
        // native — no CommonCrypto pointer handling, deterministic on device).
        let ikm = SHA256.hash(data: secretData)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(ikm)),
            salt: salt,
            info: Data("sfos-cache-v1".utf8),
            outputByteCount: keyBytes
        )
    }

    // MARK: - Sealing (AES-GCM)

    static func seal(_ plaintext: Data, key: Data) throws -> Sealed {
        guard key.count == keyBytes else { throw CryptoError.badKey }
        let nonce = try AES.GCM.Nonce(data: makeSaltBytes(count: nonceBytes))
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        var combined = Data(box.ciphertext)
        combined.append(box.tag)
        return Sealed(v: version, iv: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(), ct: combined.base64EncodedString())
    }

    static func open(_ sealed: Sealed, key: Data) throws -> Data {
        guard key.count == keyBytes else { throw CryptoError.badKey }
        return try openData(sealed, symmetricKey: SymmetricKey(data: key))
    }

    static func sealText(_ text: String, key: Data) throws -> Sealed {
        try seal(Data(text.utf8), key: key)
    }

    static func openText(_ sealed: Sealed, key: Data) throws -> String {
        let data = try open(sealed, key: key)
        guard let text = String(data: data, encoding: .utf8) else { throw CryptoError.badPayload }
        return text
    }

    // MARK: - Wrapping the device key

    static func wrap(deviceKey: Data, secret: String) throws -> Wrapped {
        guard deviceKey.count == keyBytes else { throw CryptoError.badKey }
        let salt = makeSalt()
        let kek = try deriveKey(secret: secret, salt: salt)
        let nonce = try AES.GCM.Nonce(data: makeSaltBytes(count: nonceBytes))
        let box = try AES.GCM.seal(deviceKey, using: kek, nonce: nonce)
        var combined = Data(box.ciphertext)
        combined.append(box.tag)
        return Wrapped(
            salt: salt.base64EncodedString(),
            kdf: kdfName,
            v: version,
            iv: nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ct: combined.base64EncodedString()
        )
    }

    static func unwrap(_ wrapped: Wrapped, secret: String) throws -> Data {
        guard wrapped.v == version, wrapped.kdf == kdfName, let salt = Data(base64Encoded: wrapped.salt) else { throw CryptoError.badPayload }
        let kek = try deriveKey(secret: secret, salt: salt)
        let sealed = Sealed(v: wrapped.v, iv: wrapped.iv, ct: wrapped.ct)
        let key = try openData(sealed, symmetricKey: kek)
        guard key.count == keyBytes else { throw CryptoError.badKey }
        return key
    }

    // MARK: - Serialisation helpers

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decodeSealed(_ data: Data) throws -> Sealed {
        try JSONDecoder().decode(Sealed.self, from: data)
    }

    static func decodeWrapped(_ data: Data) throws -> Wrapped {
        try JSONDecoder().decode(Wrapped.self, from: data)
    }

    // MARK: - Internals

    private static func openData(_ sealed: Sealed, symmetricKey: SymmetricKey) throws -> Data {
        guard sealed.v == version,
              let nonceData = Data(base64Encoded: sealed.iv),
              let combined = Data(base64Encoded: sealed.ct),
              combined.count >= 16 else { throw CryptoError.badPayload }
        let nonce = try AES.GCM.Nonce(data: Data(nonceData))
        let ciphertext = Data(combined.prefix(combined.count - 16))
        let tag = Data(combined.suffix(16))
        guard tag.count == 16 else { throw CryptoError.badPayload }
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: symmetricKey)
    }

    private static func makeSaltBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "system RNG unavailable")
        return Data(bytes)
    }
}
