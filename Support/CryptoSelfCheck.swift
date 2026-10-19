import Foundation

/// Executable self-check for CacheCrypto (run on the CI host — no simulator,
/// no signing). Fails loudly with a non-zero exit so a green build means the
/// crypto actually works, not merely that it compiles.
///
///     swiftc -O -o /tmp/sfos-crypto-check \
///         Support/CryptoSelfCheck.swift Sources/Offline/CacheCrypto.swift
///     /tmp/sfos-crypto-check

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        let d = detail()
        print("FAIL  \(name)\(d.isEmpty ? "" : "  :: \(d)")")
    }
}

func expectThrow<T>(_ name: String, _ body: () throws -> T) {
    do {
        _ = try body()
        failures += 1
        print("FAIL  \(name)  :: expected an error, none thrown")
    } catch {
        print("PASS  \(name)")
    }
}

// 1. key generation
let keyA = CacheCrypto.makeDeviceKey()
let keyB = CacheCrypto.makeDeviceKey()
check("device key is 32 bytes", keyA.count == CacheCrypto.keyBytes, "\(keyA.count)")
check("device keys differ", keyA != keyB)

// 2. seal / open round-trip
let message = "Log book entry — fridge 1 reads 4.2°C (£ value: 12.50)"
let sealed = try CacheCrypto.sealText(message, key: keyA)
check("sealed iv is 12 bytes", Data(base64Encoded: sealed.iv)?.count == 12)
check("sealed ct carries the 16-byte tag", (Data(base64Encoded: sealed.ct)?.count ?? 0) == Data(message.utf8).count + 16)
check("round-trip returns the original text", try CacheCrypto.openText(sealed, key: keyA) == message)

// 3. wrong key refused
expectThrow("wrong device key cannot open") { try CacheCrypto.openText(sealed, key: keyB) }

// 4. tampering refused
var tamperedBytes = Data(base64Encoded: sealed.ct)!
tamperedBytes[0] ^= 0x01
let tampered = CacheCrypto.Sealed(v: sealed.v, iv: sealed.iv, ct: tamperedBytes.base64EncodedString())
expectThrow("tampered ciphertext refused") { try CacheCrypto.openText(tampered, key: keyA) }
let badIv = CacheCrypto.Sealed(v: sealed.v, iv: Data(repeating: 0, count: 12).base64EncodedString(), ct: sealed.ct)
expectThrow("altered nonce refused") { try CacheCrypto.openText(badIv, key: keyA) }

// 5. wrapping under a password
let wrapped = try CacheCrypto.wrap(deviceKey: keyA, secret: "EmberOak26")
check("wrap records 100k iterations", wrapped.iters == 100_000, "\(wrapped.iters)")
check("wrap salt is 16 bytes", Data(base64Encoded: wrapped.salt)?.count == 16)
let unwrapped = try CacheCrypto.unwrap(wrapped, secret: "EmberOak26")
check("wrap/unwrap restores the device key", unwrapped == keyA)
// Diagnostics for the wrong-password case: is PBKDF2 actually keyed by the secret?
let probeSalt = Data(repeating: 1, count: 16)
let kA = try CacheCrypto.deriveKey(secret: "EmberOak26", salt: probeSalt).withUnsafeBytes { Data($0) }
let kB = try CacheCrypto.deriveKey(secret: "wrong-password", salt: probeSalt).withUnsafeBytes { Data($0) }
check("PBKDF2 differs across passwords", kA != kB, "A=\(kA.base64EncodedString()) B=\(kB.base64EncodedString())")
// Where exactly does the wrong password slip through?
let saltW = Data(base64Encoded: wrapped.salt)!
let rawA = try CacheCrypto.deriveKey(secret: "EmberOak26", salt: saltW, iterations: wrapped.iters).withUnsafeBytes { Data($0) }
let rawB = try CacheCrypto.deriveKey(secret: "wrong-password", salt: saltW, iterations: wrapped.iters).withUnsafeBytes { Data($0) }
check("wrap-salt KEKs differ", rawA != rawB, "A=\(rawA.base64EncodedString()) B=\(rawB.base64EncodedString())")
let manual = try CacheCrypto.seal(Data("manual probe".utf8), key: rawA)
expectThrow("manual wrong-KEK open refused") { try CacheCrypto.open(manual, key: rawB) }
var saltFlipped = wrapped
if var s = Data(base64Encoded: saltFlipped.salt) { s[0] ^= 0xFF; saltFlipped.salt = s.base64EncodedString() }
expectThrow("salt-flipped wrap refused") { try CacheCrypto.unwrap(saltFlipped, secret: "EmberOak26") }
do {
    let bad = try CacheCrypto.unwrap(wrapped, secret: "wrong-password")
    failures += 1
    print("FAIL  wrong password cannot unwrap  :: returned \(bad.count) bytes: \(bad.base64EncodedString()) (correct: \(keyA.base64EncodedString()))")
} catch {
    print("PASS  wrong password cannot unwrap  :: threw \(error)")
}
let wrappedPin = try CacheCrypto.wrap(deviceKey: keyA, secret: "2468")
let unwrappedPin = try CacheCrypto.unwrap(wrappedPin, secret: "2468")
check("short PIN wraps work too", unwrappedPin == keyA)

// 6. JSON shape matches the web layer (v / iv / ct, salt / iters / v / iv / ct)
let sealedJSON = try JSONSerialization.jsonObject(with: CacheCrypto.encode(sealed)) as! [String: Any]
check("sealed JSON has exactly v, iv, ct", Set(sealedJSON.keys) == Set(["v", "iv", "ct"]), "\(sealedJSON.keys)")
let wrappedJSON = try JSONSerialization.jsonObject(with: CacheCrypto.encode(wrapped)) as! [String: Any]
check("wrapped JSON has exactly salt, iters, v, iv, ct", Set(wrappedJSON.keys) == Set(["salt", "iters", "v", "iv", "ct"]), "\(wrappedJSON.keys)")
check("round-trip through JSON survives", try CacheCrypto.openText(CacheCrypto.decodeSealed(try CacheCrypto.encode(sealed)), key: keyA) == message)

// 7. empty payload is still sealed properly
let emptySealed = try CacheCrypto.sealText("", key: keyA)
check("empty payload round-trips", try CacheCrypto.openText(emptySealed, key: keyA) == "")

// 8. large payload (a full cached page)
let big = String(repeating: "<div>menu item £3.50</div>", count: 4000)
let bigSealed = try CacheCrypto.sealText(big, key: keyA)
check("4000-node page round-trips", try CacheCrypto.openText(bigSealed, key: keyA) == big)

print("")
if failures == 0 {
    print("crypto self-check: ALL PASS")
    exit(0)
} else {
    print("crypto self-check: \(failures) FAILURE(S)")
    exit(1)
}
