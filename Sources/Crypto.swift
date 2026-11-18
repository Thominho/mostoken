import Foundation
import CryptoKit

/// Pairing keys of paired Macs (one 32-byte key per Mac), readable only by this user.
final class TrustStore {
    static let shared = TrustStore()
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private let url: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MostOken", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("paired-macs.json")
        if let data = try? Data(contentsOf: url), let dict = try? JSONDecoder().decode([String: Data].self, from: data) {
            keys = dict
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return keys.count
    }

    func key(for id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return keys[id]
    }

    func set(_ key: Data?, for id: String) {
        lock.lock()
        keys[id] = key
        let snapshot = keys
        lock.unlock()
        persist(snapshot)
    }

    func removeAll() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
        persist([:])
    }

    private func persist(_ dict: [String: Data]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Pairing {
    private static func sorted(_ a: Data, _ b: Data) -> (Data, Data) {
        a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
    }

    /// Six digits both Macs show during pairing. A man-in-the-middle would change the public keys
    /// and therefore the code.
    static func code(_ a: Data, _ b: Data) -> String {
        let (x, y) = sorted(a, b)
        var hash = SHA256()
        hash.update(data: Data("MostOken-code".utf8))
        hash.update(data: x)
        hash.update(data: y)
        let d = Array(hash.finalize())
        let n = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return "\(s.prefix(3)) \(s.suffix(3))"
    }

    /// Long-term key shared by the two Macs, from an X25519 key agreement.
    static func pairingKey(_ mine: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        let shared = try mine.sharedSecretFromKeyAgreement(with: peer)
        let (x, y) = sorted(mine.publicKey.rawRepresentation, peerPublic)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: x + y,
                                                 sharedInfo: Data("MostOken-pairing".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Fresh key for one connection, from the pairing key and both sides' random nonces.
    static func sessionKey(pairingKey: Data, lowNonce: Data, highNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairingKey), salt: lowNonce + highNonce,
                               info: Data("MostOken-session".utf8), outputByteCount: 32)
    }

    static func randomBytes(_ n: Int) -> Data {
        Data((0..<n).map { _ in UInt8.random(in: 0...255) })
    }
}

/// ChaCha20-Poly1305 for one direction of a connection. Nonce = direction byte + message counter,
/// so every message is unique, and reordered, replayed or forged messages fail to open.
final class MessageCipher {
    private let key: SymmetricKey
    private let direction: UInt8
    private var counter: UInt64 = 0

    init(key: SymmetricKey, direction: UInt8) {
        self.key = key
        self.direction = direction
    }

    private func nextNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = direction
        for i in 0..<8 { bytes[4 + i] = UInt8((counter >> (56 - 8 * UInt64(i))) & 0xff) }
        counter += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }

    func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nextNonce())
        return box.ciphertext + box.tag
    }

    func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try ChaChaPoly.SealedBox(nonce: nextNonce(), ciphertext: data.prefix(data.count - 16),
                                           tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key)
    }
}
