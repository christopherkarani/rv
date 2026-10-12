import Foundation
import RVDomain
import Testing
@testable import RVIsolation

// MARK: - Helpers

/// 0700 temp directory for one test. Parallel-safe: every test mints its own.
private func makeEncryptedTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-encrypted-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func writeEncryptedBytes(
    at directory: URL, name: String, bytes: Data, mode: Int = 0o600
) throws {
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func writeEncryptedString(
    at directory: URL, name: String, string: String, mode: Int = 0o600
) throws {
    try writeEncryptedBytes(
        at: directory, name: name, bytes: Data(string.utf8), mode: mode
    )
}

private func readEncryptedString(at directory: URL, name: String) throws -> String {
    let data = try Data(contentsOf: directory.appendingPathComponent(name))
    return try #require(String(data: data, encoding: .utf8))
}

private func readEncryptedBytes(at directory: URL, name: String) throws -> Data {
    try Data(contentsOf: directory.appendingPathComponent(name))
}

/// Deterministic 32-byte test key (`0..<32`), injected through the
/// internal init so store tests never pay for scrypt.
private let testKeyBytes: [UInt8] = (0..<32).map { UInt8($0) }

private let otherKeyBytes: [UInt8] = (0..<32).map { UInt8(31 - $0) }

private func makeTestProvider(
    directory: URL,
    keyBytes: [UInt8] = testKeyBytes,
    defaultOwner: MCPEncryptedSecretsOwner = .org
) -> EncryptedSecretsProvider {
    EncryptedSecretsProvider(
        configDirectory: directory, keyBytes: keyBytes, defaultOwner: defaultOwner
    )
}

private func sealForTests(_ value: String, key: [UInt8] = testKeyBytes) throws -> String {
    try #require(MCPEncryptedPayload.encrypt(key: key, plaintext: value))
}

private func storeJSON(rows: [(id: String, owner: String, payload: String)]) -> String {
    let body = rows.map {
        "\"\($0.id)\":{\"owner\":\"\($0.owner)\",\"payload\":\"\($0.payload)\"}"
    }.joined(separator: ",")
    return "{\"version\":1,\"items\":{\(body)}}"
}

private func hexString(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

/// Flips a middle base64 character while staying in the alphabet, so the
/// tampered part still parses and only authentication fails.
private func tamperMiddle(_ part: Substring) -> String {
    var text = String(part)
    let index = text.index(text.startIndex, offsetBy: text.count / 2)
    text.replaceSubrange(index...index, with: text[index] == "A" ? "B" : "A")
    return text
}

private func tamperedPayload(_ payload: String, part: Int) -> String {
    let segments = payload.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var edited = segments
    edited[part] = tamperMiddle(Substring(segments[part]))
    return edited.joined(separator: ".")
}

// MARK: - Owner partition

@Suite("EncryptedSecretsOwner")
struct EncryptedSecretsOwnerTests {
    @Test func orgEmbeddedIDsFileOrg() {
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:org:slack:ws") == .org)
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:org:slack:ws:refresh") == .org
        )
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:org:slack:ws:refresh:store-probe")
                == .org
        )
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "connection:org:exa:main:token") == .org
        )
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth-client:org:app:secret") == .org
        )
    }

    @Test func userEmbeddedIDsFileUser() {
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "connection:user:notion:p:token")
                == .user
        )
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:user:gh:main") == .user)
        #expect(
            MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth-client:user:app:secret") == .user
        )
    }

    @Test func plainIDsHaveNoEmbeddedOwner() {
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "github") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "no-colons-here") == nil)
    }

    @Test func malformedIDsHaveNoEmbeddedOwner() {
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "vault:org:x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "OAUTH:org:x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:Org:x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:bogus:x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth::x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: ":org:x") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "oauth:") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: ":") == nil)
        #expect(MCPEncryptedSecretsOwner.embeddedOwner(itemID: "connection:org") == .org)
    }

    @Test func ownerForItemIDPrefersEmbeddedOverBinding() {
        #expect(
            MCPEncryptedSecretsOwner.ownerForItemID("oauth:org:a:b", defaultOwner: .user) == .org
        )
        #expect(
            MCPEncryptedSecretsOwner.ownerForItemID("oauth:user:a:b", defaultOwner: .org) == .user
        )
    }

    @Test func ownerForItemIDFallsBackToBinding() {
        #expect(MCPEncryptedSecretsOwner.ownerForItemID("github", defaultOwner: .org) == .org)
        #expect(MCPEncryptedSecretsOwner.ownerForItemID("github", defaultOwner: .user) == .user)
        #expect(MCPEncryptedSecretsOwner.ownerForItemID("", defaultOwner: .user) == .user)
    }

    @Test func ownerEquality() {
        #expect(MCPEncryptedSecretsOwner.org == .org)
        #expect(MCPEncryptedSecretsOwner.org != .user)
    }
}

// MARK: - scrypt KATs

@Suite("EncryptedSecretsScrypt")
struct EncryptedSecretsScryptTests {
    @Test func sha256OfAbc() {
        #expect(hexString(MCPScrypt.sha256(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256OfEmpty() {
        #expect(hexString(MCPScrypt.sha256([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func hmacRFC4231Case1() {
        let key = [UInt8](repeating: 0x0B, count: 20)
        #expect(hexString(MCPScrypt.hmac(key: key, message: Array("Hi There".utf8))) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    @Test func scryptRFC7914Vector1() throws {
        let parameters = try MCPScrypt.Parameters(n: 16, r: 1, p: 1, salt: [], dkLen: 64)
        #expect(hexString(MCPScrypt.derive(password: [], parameters: parameters)) == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
    }

    @Test func scryptRFC7914Vector2() throws {
        let parameters = try MCPScrypt.Parameters(
            n: 1024, r: 8, p: 16, salt: Array("NaCl".utf8), dkLen: 64
        )
        #expect(hexString(MCPScrypt.derive(password: Array("password".utf8), parameters: parameters)) == "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640")
    }

    @Test func scryptRFC7914Vector3() throws {
        let parameters = try MCPScrypt.Parameters(
            n: 16384, r: 8, p: 1, salt: Array("SodiumChloride".utf8), dkLen: 64
        )
        #expect(hexString(MCPScrypt.derive(password: Array("pleaseletmein".utf8), parameters: parameters)) == "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887")
    }

    @Test func scryptLongPassword() throws {
        let parameters = try MCPScrypt.Parameters(
            n: 16, r: 1, p: 1, salt: Array("long-salt".utf8), dkLen: 32
        )
        let password = [UInt8](repeating: 65, count: 100)
        #expect(hexString(MCPScrypt.derive(password: password, parameters: parameters)) == "c9158d4ba3b906f53335dca94d1fa0ac929654f9ed70dd07ae94f1c0cb3338fe")
    }

    @Test func executorV1ParametersArePinned() throws {
        let expected = try MCPScrypt.Parameters(
            n: 16384, r: 8, p: 1,
            salt: Array("executor-encrypted-secrets/v1".utf8), dkLen: 32
        )
        #expect(MCPScrypt.Parameters.executorV1 == expected)
    }

    @Test func executorKeyMatchesNodeDeriveKey() {
        #expect(hexString(MCPScrypt.executorKey(masterKey: "master")) == "7a3db7ab05a96c11a92f75d58bf71078b0aede65e30f4080afe534ad3b0f1f35")
    }

    @Test func invalidCostParameterThrows() throws {
        let salt = Array("s".utf8)
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 0, r: 1, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 1, r: 1, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 3, r: 1, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 1000, r: 1, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 2_097_152, r: 1, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 1_048_576, r: 2, p: 1, salt: salt, dkLen: 32)
        }
    }

    @Test func invalidBlockAndParallelParametersThrow() throws {
        let salt = Array("s".utf8)
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 0, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 257, p: 1, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 1, p: 0, salt: salt, dkLen: 32)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 1, p: 257, salt: salt, dkLen: 32)
        }
    }

    @Test func invalidDerivedLengthThrows() throws {
        let salt = Array("s".utf8)
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 1, p: 1, salt: salt, dkLen: 0)
        }
        #expect(throws: MCPScryptError.invalidParameters) {
            try MCPScrypt.Parameters(n: 16, r: 1, p: 1, salt: salt, dkLen: 1_048_577)
        }
    }
}

// MARK: - AES-GCM KATs

@Suite("EncryptedSecretsGCM")
struct EncryptedSecretsGCMTests {
    private let zeroKey = [UInt8](repeating: 0, count: 32)
    private let zeroNonce = [UInt8](repeating: 0, count: 12)

    @Test func aesGCMZeroVector() throws {
        let sealed = try MCPAES256GCM.encrypt(
            key: zeroKey, nonce: zeroNonce, plaintext: [UInt8](repeating: 0, count: 16)
        )
        #expect(hexString(sealed.ciphertext) == "cea7403d4d606b6e074ec5d3baf39d18")
        #expect(hexString(sealed.tag) == "d0d1c8a799996bf0265b98b5d48ab919")
    }

    @Test func aesGCMEmptyPlaintextVector() throws {
        let sealed = try MCPAES256GCM.encrypt(key: zeroKey, nonce: zeroNonce, plaintext: [])
        #expect(sealed.ciphertext.isEmpty)
        #expect(hexString(sealed.tag) == "530f8afbc74536b9a963b4f1c4cb738b")
    }

    @Test func aesGCMRoundTripsEveryLengthClass() throws {
        let key = testKeyBytes
        let nonce = Array(testKeyBytes.prefix(12))
        for length in [0, 1, 15, 16, 17, 31, 32, 33, 100, 1000] {
            let plaintext = (0..<length).map { UInt8($0 & 0xFF) }
            let sealed = try MCPAES256GCM.encrypt(key: key, nonce: nonce, plaintext: plaintext)
            #expect(sealed.ciphertext.count == length)
            #expect(sealed.tag.count == 16)
            let opened = try MCPAES256GCM.decrypt(
                key: key, nonce: nonce, ciphertext: sealed.ciphertext, tag: sealed.tag
            )
            #expect(opened == plaintext)
        }
    }

    @Test func aesGCMEncryptRejectsBadKeyLength() {
        #expect(throws: MCPAES256GCMError.invalidKeyLength) {
            try MCPAES256GCM.encrypt(key: [UInt8](repeating: 0, count: 31), nonce: zeroNonce, plaintext: [1])
        }
        #expect(throws: MCPAES256GCMError.invalidKeyLength) {
            try MCPAES256GCM.encrypt(key: [UInt8](repeating: 0, count: 33), nonce: zeroNonce, plaintext: [1])
        }
        #expect(throws: MCPAES256GCMError.invalidKeyLength) {
            try MCPAES256GCM.encrypt(key: [], nonce: zeroNonce, plaintext: [1])
        }
    }

    @Test func aesGCMEncryptRejectsBadNonceLength() {
        #expect(throws: MCPAES256GCMError.invalidNonceLength) {
            try MCPAES256GCM.encrypt(key: zeroKey, nonce: [UInt8](repeating: 0, count: 11), plaintext: [1])
        }
        #expect(throws: MCPAES256GCMError.invalidNonceLength) {
            try MCPAES256GCM.encrypt(key: zeroKey, nonce: [UInt8](repeating: 0, count: 13), plaintext: [1])
        }
    }

    @Test func aesGCMDecryptRejectsBadShapes() throws {
        let sealed = try MCPAES256GCM.encrypt(key: zeroKey, nonce: zeroNonce, plaintext: [9, 9])
        #expect(throws: MCPAES256GCMError.invalidKeyLength) {
            try MCPAES256GCM.decrypt(key: [0], nonce: zeroNonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
        }
        #expect(throws: MCPAES256GCMError.invalidNonceLength) {
            try MCPAES256GCM.decrypt(key: zeroKey, nonce: [0], ciphertext: sealed.ciphertext, tag: sealed.tag)
        }
        #expect(throws: MCPAES256GCMError.invalidTagLength) {
            try MCPAES256GCM.decrypt(key: zeroKey, nonce: zeroNonce, ciphertext: sealed.ciphertext, tag: [0])
        }
        #expect(throws: MCPAES256GCMError.invalidTagLength) {
            try MCPAES256GCM.decrypt(
                key: zeroKey, nonce: zeroNonce, ciphertext: sealed.ciphertext,
                tag: [UInt8](repeating: 0, count: 17)
            )
        }
    }

    @Test func aesGCMDecryptWrongTagFails() throws {
        let sealed = try MCPAES256GCM.encrypt(key: zeroKey, nonce: zeroNonce, plaintext: [1, 2, 3])
        var tag = sealed.tag
        tag[0] ^= 0x01
        let opened = try MCPAES256GCM.decrypt(
            key: zeroKey, nonce: zeroNonce, ciphertext: sealed.ciphertext, tag: tag
        )
        #expect(opened == nil)
    }

    @Test func aesGCMDecryptWrongKeyFails() throws {
        let sealed = try MCPAES256GCM.encrypt(key: zeroKey, nonce: zeroNonce, plaintext: [1, 2, 3])
        var key = zeroKey
        key[31] ^= 0x01
        let opened = try MCPAES256GCM.decrypt(
            key: key, nonce: zeroNonce, ciphertext: sealed.ciphertext, tag: sealed.tag
        )
        #expect(opened == nil)
    }

    @Test func aesGCMDecryptTamperedCiphertextFails() throws {
        let sealed = try MCPAES256GCM.encrypt(
            key: zeroKey, nonce: zeroNonce, plaintext: [UInt8](repeating: 7, count: 40)
        )
        var ciphertext = sealed.ciphertext
        ciphertext[20] ^= 0x80
        let opened = try MCPAES256GCM.decrypt(
            key: zeroKey, nonce: zeroNonce, ciphertext: ciphertext, tag: sealed.tag
        )
        #expect(opened == nil)
    }

    @Test func constantTimeEqualBehavior() {
        #expect(MCPAES256GCM.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        #expect(MCPAES256GCM.constantTimeEqual([], []) == true)
        #expect(MCPAES256GCM.constantTimeEqual([1, 2, 3], [1, 2, 4]) == false)
        #expect(MCPAES256GCM.constantTimeEqual([1, 2, 3], [1, 2]) == false)
        #expect(MCPAES256GCM.constantTimeEqual([1], [1, 2]) == false)
    }
}

// MARK: - Payload envelope

@Suite("EncryptedSecretsPayload")
struct EncryptedSecretsPayloadTests {
    @Test func payloadRoundTrips() throws {
        for value in ["[REDACTED]", "", "héllo🔐", String(repeating: "x", count: 10_000)] {
            let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: value))
            #expect(payload.hasPrefix("v1."))
            #expect(payload.split(separator: ".", omittingEmptySubsequences: false).count == 4)
            #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: payload) == value)
        }
    }

    @Test func payloadMatchesNodeByteForByte() throws {
        let sealed = try #require(MCPEncryptedPayload.encrypt(
            key: testKeyBytes, plaintext: "swift-seals-this",
            nonce: Array(testKeyBytes.prefix(12))
        ))
        #expect(sealed == "v1.AAECAwQFBgcICQoL.Bt1yzy50CHd6ebcLmd8Ltg==.NHW/fbHIsX7sLeSmxYERHg==")
        #expect(MCPEncryptedPayload.decrypt(
            key: testKeyBytes,
            payload: "v1.AAECAwQFBgcICQoL.Bt1yzy50CHd6ebcLmd8Ltg==.NHW/fbHIsX7sLeSmxYERHg=="
        ) == "swift-seals-this")
    }

    @Test func nodeMigrationPayloadsOpen() {
        let key = MCPScrypt.executorKey(masterKey: "migration-master")
        #expect(hexString(key) == "703ba4f7e0cb15d2afa40823e21c9ea237d336d1e8fc17c4cf2325509ecb7f1d")
        #expect(MCPEncryptedPayload.decrypt(
            key: key,
            payload: "v1.AQIDBAUGBwgJCgsM.YDap57sY6Fa7NfNvpmY0Iw==.ZyC2docixZ3FEo7DWsXTOhXKNNiA1QA2Mr6Exw=="
        ) == "executor-ciphertext-migrates")
        #expect(MCPEncryptedPayload.decrypt(
            key: key, payload: "v1.AQIDBAUGBwgJCgsM.rRnLVYYK/YI+EylHZmj4Qw==."
        ) == "")
        let resealed = MCPEncryptedPayload.encrypt(
            key: key, plaintext: "executor-ciphertext-migrates",
            nonce: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        )
        #expect(resealed == "v1.AQIDBAUGBwgJCgsM.YDap57sY6Fa7NfNvpmY0Iw==.ZyC2docixZ3FEo7DWsXTOhXKNNiA1QA2Mr6Exw==")
    }

    @Test func reviewerNodeVectorsOpen() {
        // Independently minted Node AES-256-GCM vectors (review cross-check,
        // key 0..<32): the Swift side opens ciphertext it has never seen,
        // and the wrong key rejects every one.
        let vectors = [
            ("review-probe-1", "v1.CQgHBgUEAwIBAAsW.JLxsGl+jwMfxj45U8Sl51w==.mzX8wT2wmlEdMiXJGow="),
            ("", "v1.AAAAAAAAAAAAAAAB.Nn74KIgxVXQI4QKVChbiag==."),
            (
                String(repeating: "x", count: 100),
                "v1.//79/Pv6+fj39vX0.r0iO++m+mEVMCCo5ZX6h0w==.DpZ39ZBOE/8fsZbB0rnto+EHP1UOjwRsZsqIhVsogUMyRgFrCnPfYEaVaWm/31L8rPAcaa7W4sRvjZMMWw083y1uvFR0xvJQNP8hnKs+AU6DiWYFrMrKgNHVHvi/5XE2gw+VAQ=="
            ),
        ]
        for (plaintext, payload) in vectors {
            #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: payload) == plaintext)
            #expect(MCPEncryptedPayload.decrypt(key: otherKeyBytes, payload: payload) == nil)
        }
    }

    @Test func payloadTruncationFailsClosed() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(
            key: testKeyBytes, plaintext: "truncate-me"
        ))
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: String(payload.dropLast())) == nil)
        #expect(MCPEncryptedPayload.decrypt(
            key: testKeyBytes, payload: String(payload.dropLast(4))
        ) == nil)
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let clippedTag = [parts[0], parts[1], String(parts[2].dropLast()), parts[3]].joined(separator: ".")
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: clippedTag) == nil)
    }

    @Test func payloadDecryptRejectsBadArity() {
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "") == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "v1") == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "v1.a.b") == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "v1.a.b.c.d") == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "...") == nil)
    }

    @Test func payloadDecryptRejectsBadVersion() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "v"))
        let rest = payload.split(separator: ".", omittingEmptySubsequences: false).dropFirst().joined(separator: ".")
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "v0." + rest) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "V1." + rest) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: "." + rest) == nil)
    }

    @Test func payloadDecryptRejectsBadBase64() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "v"))
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", "!!!", parts[2], parts[3]].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", parts[1], "!!!", parts[3]].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", parts[1], parts[2], "!!!"].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", "YWI", parts[2], parts[3]].joined(separator: ".")) == nil)
    }

    @Test func payloadDecryptRejectsWrongLengths() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "v"))
        let parts = payload.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let short8 = Data([UInt8](repeating: 0, count: 8)).base64EncodedString()
        let long16 = Data([UInt8](repeating: 0, count: 16)).base64EncodedString()
        let long20 = Data([UInt8](repeating: 0, count: 20)).base64EncodedString()
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", short8, parts[2], parts[3]].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", long16, parts[2], parts[3]].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", parts[1], short8, parts[3]].joined(separator: ".")) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: ["v1", parts[1], long20, parts[3]].joined(separator: ".")) == nil)
    }

    @Test func payloadDecryptWrongKeyFails() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "v"))
        #expect(MCPEncryptedPayload.decrypt(key: otherKeyBytes, payload: payload) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: [UInt8](repeating: 9, count: 32), payload: payload) == nil)
    }

    @Test func payloadTamperFailsClosed() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(
            key: testKeyBytes, plaintext: String(repeating: "tamper-me", count: 4)
        ))
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: tamperedPayload(payload, part: 1)) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: tamperedPayload(payload, part: 2)) == nil)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: tamperedPayload(payload, part: 3)) == nil)
    }

    @Test func payloadRandomNoncesDiffer() throws {
        let first = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "same"))
        let second = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "same"))
        #expect(first != second)
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: first) == "same")
        #expect(MCPEncryptedPayload.decrypt(key: testKeyBytes, payload: second) == "same")
    }

    @Test func payloadEncryptRejectsShortKey() {
        #expect(MCPEncryptedPayload.encrypt(key: [1, 2, 3], plaintext: "v") == nil)
        #expect(MCPEncryptedPayload.encrypt(key: [], plaintext: "v") == nil)
    }

    @Test func payloadDecryptShortKeyFails() throws {
        let payload = try #require(MCPEncryptedPayload.encrypt(key: testKeyBytes, plaintext: "v"))
        #expect(MCPEncryptedPayload.decrypt(key: [1, 2, 3], payload: payload) == nil)
    }
}

// MARK: - Master key

@Suite("EncryptedSecretsMasterKey")
struct EncryptedSecretsMasterKeyTests {
    @Test func initThrowsOnEmptyMaster() throws {
        let directory = try makeEncryptedTempDir()
        #expect(throws: EncryptedSecretsConfigError.emptyMasterKey) {
            try EncryptedSecretsProvider(
                configDirectory: directory, masterKey: "", defaultOwner: .org
            )
        }
    }

    @Test func initSucceedsAndRoundTrips() throws {
        let directory = try makeEncryptedTempDir()
        let provider = try EncryptedSecretsProvider(
            configDirectory: directory, masterKey: "master", defaultOwner: .org
        )
        #expect(provider.id == "encrypted")
        try provider.set(item: "github", value: "ghp_xyz")
        #expect(try provider.get(item: "github") == "ghp_xyz")
    }

    @Test func loadMasterKeyPrefersEnv() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secret.key", string: "key-file-value")
        let loaded = EncryptedSecretsProvider.loadMasterKey(
            environment: ["EXECUTOR_SECRET_KEY": "env-value"], keyFileDirectory: directory
        )
        #expect(loaded == .success("env-value"))
    }

    @Test func loadMasterKeyTrimsEnv() throws {
        let directory = try makeEncryptedTempDir()
        let loaded = EncryptedSecretsProvider.loadMasterKey(
            environment: ["EXECUTOR_SECRET_KEY": "  padded\t\n"], keyFileDirectory: directory
        )
        #expect(loaded == .success("padded"))
    }

    @Test func loadMasterKeyBlankEnvFallsThroughToKeyFile() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secret.key", string: "key-file-value")
        let loaded = EncryptedSecretsProvider.loadMasterKey(
            environment: ["EXECUTOR_SECRET_KEY": "  \t\n "], keyFileDirectory: directory
        )
        #expect(loaded == .success("key-file-value"))
    }

    @Test func loadMasterKeyFallsBackToKeyFile() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secret.key", string: "  file-key\n")
        let loaded = EncryptedSecretsProvider.loadMasterKey(
            environment: [:], keyFileDirectory: directory
        )
        #expect(loaded == .success("file-key"))
    }

    @Test func loadMasterKeyAbsentWhenNoEnvAndNoKeyFile() throws {
        let directory = try makeEncryptedTempDir()
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: directory)
                == .success(nil)
        )
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: nil)
                == .success(nil)
        )
        let missing = directory.appendingPathComponent("missing-dir")
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: missing)
                == .success(nil)
        )
    }

    @Test func loadMasterKeyFailsWhenKeyFileUnusable() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secret.key", string: "k", mode: 0o644)
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: directory)
                == .failure(.keyUnusable)
        )
        let oversized = try makeEncryptedTempDir()
        try writeEncryptedString(
            at: oversized, name: "secret.key", string: String(repeating: "k", count: 5000)
        )
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: oversized)
                == .failure(.keyUnusable)
        )
        let symlinked = try makeEncryptedTempDir()
        let target = symlinked.appendingPathComponent("secret-real.key")
        try "real-key".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: symlinked.appendingPathComponent("secret.key"), withDestinationURL: target
        )
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: symlinked)
                == .failure(.keyUnusable)
        )
    }

    @Test func loadMasterKeyAbsentWhenKeyFileBlank() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secret.key", string: " \n\t ")
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: directory)
                == .success(nil)
        )
    }

    @Test func loadMasterKeyFailsWhenKeyFileBinary() throws {
        let binary = try makeEncryptedTempDir()
        try writeEncryptedBytes(at: binary, name: "secret.key", bytes: Data([0xFF, 0xFE, 0x00]))
        #expect(
            EncryptedSecretsProvider.loadMasterKey(environment: [:], keyFileDirectory: binary)
                == .failure(.keyUnusable)
        )
    }

    @Test func generateMasterKeyIs32RandomBytes() throws {
        let first = EncryptedSecretsProvider.generateMasterKey()
        let second = EncryptedSecretsProvider.generateMasterKey()
        #expect(first != second)
        let firstBytes = try #require(Data(base64Encoded: first))
        let secondBytes = try #require(Data(base64Encoded: second))
        #expect(firstBytes.count == 32)
        #expect(secondBytes.count == 32)
    }
}

// MARK: - Store CRUD + broker surface

@Suite("EncryptedSecretsStore")
struct EncryptedSecretsStoreTests {
    @Test func descriptionRedactsKeyBytes() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(
            directory: directory, keyBytes: [9, 8, 7, 6], defaultOwner: .user
        )
        for rendered in [String(describing: provider), String(reflecting: provider)] {
            #expect(rendered.contains("9, 8, 7, 6") == false)
            #expect(
                rendered == "EncryptedSecretsProvider(id: \"encrypted\", defaultOwner: user)"
            )
        }
    }

    @Test func providerIdentityIsPinned() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        #expect(provider.id == "encrypted")
        #expect(EncryptedSecretsProvider.fileName == "secrets-encrypted.json")
        #expect(EncryptedSecretsProvider.maximumBytes == 65_536)
        #expect(EncryptedSecretsProvider.maximumItems == 256)
        #expect(EncryptedSecretsProvider.masterKeyEnvironmentVariable == "EXECUTOR_SECRET_KEY")
        #expect(EncryptedSecretsProvider.masterKeyFileName == "secret.key")
    }

    @Test func setThenGetReturnsPlaintext() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "github", value: "ghp_xyz")
        #expect(try provider.get(item: "github") == "ghp_xyz")
    }

    @Test func storesCiphertextAtRest() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "github", value: "[REDACTED]")
        let stored = try readEncryptedString(at: directory, name: "secrets-encrypted.json")
        #expect(stored.contains("[REDACTED]") == false)
        #expect(stored.contains("v1."))
        let payloadStart = try #require(stored.range(of: "v1."))
        let payload = String(stored[payloadStart.lowerBound...].prefix(while: { $0 != "\"" }))
        #expect(payload.split(separator: ".").count == 4)
        for byte in payload.utf8 where byte != UInt8(ascii: ".") {
            let ok = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 43 || byte == 47 || byte == 61
            #expect(ok)
        }
    }

    @Test func getMissingReturnsNil() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        #expect(try provider.get(item: "absent") == nil)
        try provider.set(item: "present", value: "v")
        #expect(try provider.get(item: "absent") == nil)
    }

    @Test func hasAndDeleteReflectPresence() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        #expect(try provider.has(item: "k") == false)
        try provider.set(item: "k", value: "v")
        #expect(try provider.has(item: "k"))
        try provider.delete(item: "k")
        #expect(try provider.has(item: "k") == false)
        try provider.delete(item: "k")
        #expect(try provider.has(item: "k") == false)
    }

    @Test func listSurfacesStoredIDs() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        #expect(try provider.list().isEmpty)
        try provider.set(item: "beta", value: "b")
        try provider.set(item: "alpha", value: "a")
        let entries = try provider.list()
        #expect(entries.map(\.id) == ["alpha", "beta"])
        #expect(entries.allSatisfy { $0.owner == .org })
        #expect(entries.contains(MCPEncryptedSecretEntry(id: "alpha", owner: .org)))
    }

    @Test func overwriteUpdatesValue() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "k", value: "first")
        try provider.set(item: "k", value: "second")
        #expect(try provider.get(item: "k") == "second")
        #expect(try provider.list().count == 1)
    }

    @Test func emptyValueRoundTrips() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "empty", value: "")
        #expect(try provider.has(item: "empty"))
        #expect(try provider.get(item: "empty") == "")
    }

    @Test func setRejectsInvalidItems() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        let bad = ["", String(repeating: "i", count: 257), "has\0nul", "has\nlf", "has\rcr"]
        for item in bad {
            #expect(throws: EncryptedSecretsStoreError.invalidItem) {
                try provider.set(item: item, value: "v")
            }
        }
        #expect(try provider.list().isEmpty)
    }

    @Test func setRejectsInvalidItemOnPopulatedStore() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "ok", value: "v")
        let before = try readEncryptedBytes(at: directory, name: "secrets-encrypted.json")
        #expect(throws: EncryptedSecretsStoreError.invalidItem) {
            try provider.set(item: "", value: "v")
        }
        #expect(try readEncryptedBytes(at: directory, name: "secrets-encrypted.json") == before)
    }

    @Test func invalidLabelsReadAsAbsent() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "ok", value: "v")
        #expect(try provider.get(item: "bad\nlabel") == nil)
        #expect(try provider.has(item: "bad\nlabel") == false)
        try provider.delete(item: "bad\nlabel")
        #expect(try provider.get(item: "ok") == "v")
    }

    @Test func deleteMissingSucceeds() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.delete(item: "nope")
        #expect(try provider.list().isEmpty)
    }

    @Test func deleteTargetsEmbeddedPartition() throws {
        let directory = try makeEncryptedTempDir()
        let payload = try sealForTests("tok")
        try writeEncryptedString(
            at: directory, name: "secrets-encrypted.json",
            string: storeJSON(rows: [(id: "oauth:org:slack:ws", owner: "user", payload: payload)])
        )
        let provider = makeTestProvider(directory: directory, defaultOwner: .org)
        try provider.delete(item: "oauth:org:slack:ws")
        #expect(try provider.get(item: "oauth:org:slack:ws") == "tok")
        #expect(try provider.has(item: "oauth:org:slack:ws"))
        try writeEncryptedString(
            at: directory, name: "secrets-encrypted.json",
            string: storeJSON(rows: [(id: "oauth:org:slack:ws", owner: "org", payload: payload)])
        )
        try provider.delete(item: "oauth:org:slack:ws")
        #expect(try provider.has(item: "oauth:org:slack:ws") == false)
    }

    @Test func unscopedIDsFallBackToBinding() throws {
        let userDirectory = try makeEncryptedTempDir()
        let userProvider = makeTestProvider(directory: userDirectory, defaultOwner: .user)
        try userProvider.set(item: "github", value: "v")
        #expect(try userProvider.list() == [MCPEncryptedSecretEntry(id: "github", owner: .user)])
        let orgDirectory = try makeEncryptedTempDir()
        let orgProvider = makeTestProvider(directory: orgDirectory, defaultOwner: .org)
        try orgProvider.set(item: "github", value: "v")
        #expect(try orgProvider.list() == [MCPEncryptedSecretEntry(id: "github", owner: .org)])
    }

    @Test func orgEmbeddedIDsFileOrgDespiteUserBinding() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory, defaultOwner: .user)
        try provider.set(item: "oauth:org:slack:ws", value: "a")
        try provider.set(item: "oauth:org:slack:ws:refresh", value: "b")
        try provider.set(item: "connection:org:exa:main:token", value: "c")
        try provider.set(item: "oauth-client:org:app:secret", value: "d")
        let entries = try provider.list()
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { $0.owner == .org })
    }

    @Test func userEmbeddedIDFilesUserDespiteOrgBinding() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory, defaultOwner: .org)
        try provider.set(item: "connection:user:notion:p:token", value: "private")
        #expect(
            try provider.list()
                == [MCPEncryptedSecretEntry(id: "connection:user:notion:p:token", owner: .user)]
        )
    }

    @Test func setWithShortKeyFailsClosed() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory, keyBytes: [1, 2, 3])
        #expect(throws: EncryptedSecretsStoreError.encryptFailed) {
            try provider.set(item: "k", value: "v")
        }
        #expect(try provider.list().isEmpty)
    }
}

// MARK: - Broker surface (resolve/health)

@Suite("EncryptedSecretsBrokerSurface")
struct EncryptedSecretsBrokerSurfaceTests {
    // NOTE: these refs use provider "encrypted" because `resolve` guards
    // `ref.provider == id` like its siblings; the wrong-provider arm is
    // pinned by `resolveWrongProviderIsInvalidRef` below.
    @Test func resolveWrongProviderIsInvalidRef() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "github", value: "ghp_xyz")
        let foreign = try SecretRef(provider: "env", item: "github")
        await #expect(throws: SecretsError.invalidRef("encrypted")) {
            try await provider.resolve(foreign)
        }
    }

    @Test func resolveReturnsText() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "github", value: "ghp_xyz")
        let ref = try SecretRef(provider: "encrypted", item: "github")
        #expect(try await provider.resolve(ref) == .text("ghp_xyz"))
    }

    @Test func resolveMissingIsNotFound() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        let missing = try SecretRef(provider: "encrypted", item: "absent")
        await #expect(throws: SecretsError.notFound("encrypted")) {
            try await provider.resolve(missing)
        }
        try provider.set(item: "present", value: "v")
        await #expect(throws: SecretsError.notFound("encrypted")) {
            try await provider.resolve(missing)
        }
    }

    @Test func resolveWithFieldIsNotFound() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "github", value: "v")
        let fielded = try SecretRef(provider: "encrypted", item: "github", field: "token")
        await #expect(throws: SecretsError.notFound("encrypted")) {
            try await provider.resolve(fielded)
        }
    }

    @Test func resolveTamperedIsProviderDown() async throws {
        let directory = try makeEncryptedTempDir()
        let payload = try sealForTests("sekret")
        let tampered = tamperedPayload(payload, part: 2)
        try writeEncryptedString(
            at: directory, name: "secrets-encrypted.json",
            string: storeJSON(rows: [(id: "k", owner: "org", payload: tampered)])
        )
        let provider = makeTestProvider(directory: directory)
        #expect(throws: EncryptedSecretsStoreError.decryptFailed) {
            try provider.get(item: "k")
        }
        let ref = try SecretRef(provider: "encrypted", item: "k")
        await #expect(throws: SecretsError.providerDown("encrypted")) {
            try await provider.resolve(ref)
        }
    }

    @Test func resolveWrongKeyIsProviderDown() async throws {
        let directory = try makeEncryptedTempDir()
        try makeTestProvider(directory: directory, keyBytes: testKeyBytes).set(item: "k", value: "v")
        let reader = makeTestProvider(directory: directory, keyBytes: otherKeyBytes)
        let ref = try SecretRef(provider: "encrypted", item: "k")
        await #expect(throws: SecretsError.providerDown("encrypted")) {
            try await reader.resolve(ref)
        }
    }

    @Test func resolveUnreadableStoreIsProviderDown() async throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secrets-encrypted.json", string: "{}", mode: 0o644)
        let provider = makeTestProvider(directory: directory)
        let ref = try SecretRef(provider: "encrypted", item: "k")
        await #expect(throws: SecretsError.providerDown("encrypted")) {
            try await provider.resolve(ref)
        }
    }

    @Test func healthTrueWhenLoadable() async throws {
        let empty = try makeEncryptedTempDir()
        #expect(await makeTestProvider(directory: empty).health() == ProviderHealth(ok: true))
        let populated = try makeEncryptedTempDir()
        try makeTestProvider(directory: populated).set(item: "k", value: "v")
        #expect(await makeTestProvider(directory: populated).health() == ProviderHealth(ok: true))
        let missing = empty.appendingPathComponent("missing-dir")
        #expect(await makeTestProvider(directory: missing).health() == ProviderHealth(ok: true))
    }

    @Test func healthFalseWhenUnreadable() async throws {
        let corrupt = try makeEncryptedTempDir()
        try writeEncryptedString(at: corrupt, name: "secrets-encrypted.json", string: "not json")
        #expect(await makeTestProvider(directory: corrupt).health() == ProviderHealth(ok: false))
        let unsafe = try makeEncryptedTempDir()
        try writeEncryptedString(at: unsafe, name: "secrets-encrypted.json", string: "{}", mode: 0o644)
        #expect(await makeTestProvider(directory: unsafe).health() == ProviderHealth(ok: false))
    }

    // Parent-added factory construction: a loadable master key appends
    // the provider to the factory set with the org default owner. Routing
    // through the broker is proven by
    // `makeBrokerRoutesEncryptedRefsWhenKeyPresent` in
    // SecretsProviderFactoryTests.
    @Test func factoryIncludesEncryptedProviderWhenKeyPresent() async throws {
        let directory = try makeEncryptedTempDir()
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: directory,
            environment: [EncryptedSecretsProvider.masterKeyEnvironmentVariable: "registry-route-key"]
        )
        let encrypted = try #require(providers.compactMap { $0 as? EncryptedSecretsProvider }.first)
        #expect(encrypted.id == "encrypted")
        #expect(encrypted.defaultOwner == .org)
        try encrypted.set(item: "github", value: "ghp_registry")
        let ref = try SecretRef(provider: "encrypted", item: "github")
        #expect(try await encrypted.resolve(ref) == .text("ghp_registry"))
    }

    @Test func factoryOmitsEncryptedProviderWithoutKey() throws {
        let directory = try makeEncryptedTempDir()
        let providers = try SecretsProviderFactory.makeProviders(
            configDirectory: directory, environment: [:]
        )
        #expect(providers.compactMap { $0 as? EncryptedSecretsProvider }.isEmpty)
    }
}

// MARK: - Document codec

@Suite("EncryptedSecretsCodec")
struct EncryptedSecretsCodecTests {
    @Test func decodeRejectsGarbage() {
        for garbage in ["not json", "", "{", "[]", "null", "{\"version\":1}"] {
            #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
                try EncryptedSecretsProvider.decode(Data(garbage.utf8))
            }
        }
    }

    @Test func decodeRejectsBadVersion() throws {
        let payload = try sealForTests("v")
        for version in [0, 2, -1, 99] {
            let json = "{\"version\":\(version),\"items\":{\"k\":{\"owner\":\"org\",\"payload\":\"\(payload)\"}}}"
            #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
                try EncryptedSecretsProvider.decode(Data(json.utf8))
            }
        }
    }

    @Test func decodeRejectsUnknownKeys() throws {
        let payload = try sealForTests("v")
        let smuggledTop = "{\"version\":1,\"items\":{},\"extra\":1}"
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(smuggledTop.utf8))
        }
        let smuggledRow = "{\"version\":1,\"items\":{\"k\":{\"owner\":\"org\",\"payload\":\"\(payload)\",\"x\":1}}}"
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(smuggledRow.utf8))
        }
    }

    @Test func decodeRejectsBadRows() throws {
        let payload = try sealForTests("v")
        let badOwner = storeJSON(rows: [(id: "k", owner: "bogus", payload: payload)])
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(badOwner.utf8))
        }
        let emptyPayload = storeJSON(rows: [(id: "k", owner: "org", payload: "")])
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(emptyPayload.utf8))
        }
        let badLabel = storeJSON(rows: [(id: "bad\nlabel", owner: "org", payload: payload)])
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(badLabel.utf8))
        }
        let emptyLabel = storeJSON(rows: [(id: "", owner: "org", payload: payload)])
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(emptyLabel.utf8))
        }
    }

    @Test func decodeRejectsTooManyItems() throws {
        let payload = try sealForTests("v")
        let rows = (0...256).map { (id: "k\($0)", owner: "org", payload: payload) }
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try EncryptedSecretsProvider.decode(Data(storeJSON(rows: rows).utf8))
        }
        let fitting = (0..<256).map { (id: "k\($0)", owner: "org", payload: payload) }
        let decoded = try EncryptedSecretsProvider.decode(Data(storeJSON(rows: fitting).utf8))
        #expect(decoded.count == 256)
    }

    @Test func decodeRejectsWrongTypes() {
        for json in [
            "{\"version\":\"1\",\"items\":{}}",
            "{\"version\":1,\"items\":[]}",
            "{\"version\":1,\"items\":{\"k\":{\"owner\":\"org\"}}}",
            "{\"version\":1,\"items\":{\"k\":{\"payload\":\"x\"}}}",
            "{\"version\":1,\"items\":{\"k\":null}}",
        ] {
            #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
                try EncryptedSecretsProvider.decode(Data(json.utf8))
            }
        }
    }

    @Test func setOnCorruptStoreThrowsAndLeavesUntouched() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(at: directory, name: "secrets-encrypted.json", string: "{oops")
        let provider = makeTestProvider(directory: directory)
        let before = try readEncryptedBytes(at: directory, name: "secrets-encrypted.json")
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try provider.set(item: "k", value: "v")
        }
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try provider.has(item: "k")
        }
        #expect(throws: EncryptedSecretsStoreError.corruptDocument) {
            try provider.list()
        }
        #expect(try readEncryptedBytes(at: directory, name: "secrets-encrypted.json") == before)
    }

    @Test func encodeIsCanonical() {
        let empty = EncryptedSecretsProvider.encode(items: [:])
        #expect(String(data: empty, encoding: .utf8) == "{\"version\":1,\"items\":{}}")
        let rows = [
            "beta": MCPEncryptedSecretsRow(owner: .user, payload: "v1.b"),
            "alpha": MCPEncryptedSecretsRow(owner: .org, payload: "v1.a"),
        ]
        let encoded = EncryptedSecretsProvider.encode(items: rows)
        #expect(String(data: encoded, encoding: .utf8) == "{\"version\":1,\"items\":{\"alpha\":{\"owner\":\"org\",\"payload\":\"v1.a\"},\"beta\":{\"owner\":\"user\",\"payload\":\"v1.b\"}}}")
    }

    @Test func encodeEscapesLabels() throws {
        let nasty = "q\"\\\u{01}\u{1B}\u{2713}"
        let rows = ["a\(nasty)b": MCPEncryptedSecretsRow(owner: .org, payload: "v1.x")]
        let encoded = EncryptedSecretsProvider.encode(items: rows)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("\\\""))
        #expect(text.contains("\\\\"))
        #expect(text.contains("\\u0001"))
        #expect(text.contains("\\u001b"))
        #expect(text.contains("✓"))
        let decoded = try EncryptedSecretsProvider.decode(encoded)
        #expect(decoded["a\(nasty)b"]?.payload == "v1.x")
    }

    // No decode round-trip below by design: ids carrying LF/CR are
    // undecodable (`SecretLabels` rejects them), so only the encoded bytes
    // are pinned. Quote/backslash/C0 arms round-trip in the test above.
    @Test func encodeShortEscapes() throws {
        let controls = "\u{08}\u{09}\u{0A}\u{0C}\u{0D}"
        let rows = [controls: MCPEncryptedSecretsRow(owner: .user, payload: "v1.y")]
        let encoded = EncryptedSecretsProvider.encode(items: rows)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("\\b\\t\\n\\f\\r"))
    }

    @Test func setEnforcesItemCap() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        for index in 0..<256 {
            try provider.set(item: "k\(index)", value: "v")
        }
        #expect(try provider.list().count == 256)
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try provider.set(item: "k256", value: "v")
        }
        #expect(try provider.list().count == 256)
        #expect(try provider.has(item: "k256") == false)
        try provider.set(item: "k0", value: "overwrite-still-fits")
        #expect(try provider.get(item: "k0") == "overwrite-still-fits")
    }

    @Test func setEnforcesByteCap() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try provider.set(item: "big", value: String(repeating: "v", count: 70_000))
        }
        #expect(try provider.list().isEmpty)
    }

    @Test func oversizedFileIsUnreadable() throws {
        let directory = try makeEncryptedTempDir()
        try writeEncryptedString(
            at: directory, name: "secrets-encrypted.json",
            string: String(repeating: "{", count: 70_000)
        )
        let provider = makeTestProvider(directory: directory)
        #expect(throws: EncryptedSecretsStoreError.storeUnreadable) {
            try provider.get(item: "k")
        }
    }

    @Test func unsafeLocationsAreUnreadable() throws {
        let providerFile = try makeEncryptedTempDir()
        try writeEncryptedString(at: providerFile, name: "secrets-encrypted.json", string: "{}", mode: 0o644)
        #expect(throws: EncryptedSecretsStoreError.storeUnreadable) {
            try makeTestProvider(directory: providerFile).get(item: "k")
        }
        let providerDir = try makeEncryptedTempDir()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770], ofItemAtPath: providerDir.path
        )
        #expect(throws: EncryptedSecretsStoreError.storeUnreadable) {
            try makeTestProvider(directory: providerDir).get(item: "k")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: providerDir.path
        )
        let providerLink = try makeEncryptedTempDir()
        try writeEncryptedString(at: providerLink, name: "real.json", string: "{}")
        try FileManager.default.createSymbolicLink(
            atPath: providerLink.appendingPathComponent("secrets-encrypted.json").path,
            withDestinationPath: providerLink.appendingPathComponent("real.json").path
        )
        #expect(throws: EncryptedSecretsStoreError.storeUnreadable) {
            try makeTestProvider(directory: providerLink).get(item: "k")
        }
    }

    @Test func missingLocationsLoadEmpty() throws {
        let missing = try makeEncryptedTempDir().appendingPathComponent("missing-dir")
        let provider = makeTestProvider(directory: missing)
        #expect(try provider.get(item: "k") == nil)
        #expect(try provider.has(item: "k") == false)
        #expect(try provider.list().isEmpty)
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try provider.set(item: "k", value: "v")
        }
    }
}

// MARK: - Write mechanics

@Suite("EncryptedSecretsWrite")
struct EncryptedSecretsWriteTests {
    @Test func writeFailsWhenDirectoryMissing() throws {
        let missing = try makeEncryptedTempDir().appendingPathComponent("missing-dir")
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try EncryptedSecretsProvider.write(
                bytes: Data("{}".utf8), expected: nil, directory: missing
            )
        }
    }

    @Test func writeFailsWhenDirectoryUntrusted() throws {
        let directory = try makeEncryptedTempDir()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770], ofItemAtPath: directory.path
        )
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try EncryptedSecretsProvider.write(
                bytes: Data("{}".utf8), expected: nil, directory: directory
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }

    @Test func writeFailsOnStaleIdentity() throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        try provider.set(item: "a", value: "1")
        let stale = try #require(EncryptedSecretsProvider.identityOfLiveFile(directory: directory))
        try provider.set(item: "b", value: "2")
        let live = try readEncryptedBytes(at: directory, name: "secrets-encrypted.json")
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try EncryptedSecretsProvider.write(
                bytes: Data("{\"version\":1,\"items\":{}}".utf8),
                expected: stale, directory: directory
            )
        }
        #expect(try readEncryptedBytes(at: directory, name: "secrets-encrypted.json") == live)
        let fresh = try #require(EncryptedSecretsProvider.identityOfLiveFile(directory: directory))
        #expect(fresh != stale)
        try EncryptedSecretsProvider.write(
            bytes: live, expected: fresh, directory: directory
        )
    }

    @Test func writeFailsWhenStagingFails() throws {
        let directory = try makeEncryptedTempDir()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try EncryptedSecretsProvider.write(
                bytes: Data("{}".utf8), expected: nil, directory: directory
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
    }

    @Test func writeFailsWhenCommitFails() throws {
        let directory = try makeEncryptedTempDir()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("secrets-encrypted.json"),
            withIntermediateDirectories: false
        )
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try EncryptedSecretsProvider.write(
                bytes: Data("{}".utf8), expected: nil, directory: directory
            )
        }
    }

    @Test func writeSkipsVerifyWhenFileAbsent() throws {
        let directory = try makeEncryptedTempDir()
        let bytes = Data("{\"version\":1,\"items\":{}}".utf8)
        try EncryptedSecretsProvider.write(bytes: bytes, expected: nil, directory: directory)
        #expect(try readEncryptedBytes(at: directory, name: "secrets-encrypted.json") == bytes)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("secrets-encrypted.json").path
        )
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func identityOfLiveFileStates() throws {
        let directory = try makeEncryptedTempDir()
        #expect(EncryptedSecretsProvider.identityOfLiveFile(directory: directory) == nil)
        let missing = directory.appendingPathComponent("missing-dir")
        #expect(EncryptedSecretsProvider.identityOfLiveFile(directory: missing) == nil)
        try makeTestProvider(directory: directory).set(item: "k", value: "v")
        let first = try #require(EncryptedSecretsProvider.identityOfLiveFile(directory: directory))
        let second = try #require(EncryptedSecretsProvider.identityOfLiveFile(directory: directory))
        #expect(first == second)
    }
}

// MARK: - Concurrency

@Suite("EncryptedSecretsConcurrency")
struct EncryptedSecretsConcurrencyTests {
    @Test func concurrentSetsOnOneInstance() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        let count = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try provider.set(item: "k\(index)", value: "v\(index)")
                }
            }
            try await group.waitForAll()
        }
        #expect(try provider.list().count == count)
        for index in 0..<count {
            #expect(try provider.get(item: "k\(index)") == "v\(index)")
        }
    }

    @Test func mixedConcurrentOpsStayConsistent() async throws {
        let directory = try makeEncryptedTempDir()
        let provider = makeTestProvider(directory: directory)
        for index in 0..<10 {
            try provider.set(item: "seed\(index)", value: "v")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { try provider.set(item: "fresh\(index)", value: "v") }
                group.addTask { _ = try provider.get(item: "seed\(index)") }
                group.addTask { _ = try provider.list() }
                group.addTask { _ = try provider.has(item: "seed\(index)") }
                group.addTask { try provider.delete(item: "seed\(index)") }
            }
            try await group.waitForAll()
        }
        let entries = try provider.list()
        #expect(entries.count == 10)
        for entry in entries {
            #expect(try provider.get(item: entry.id) == "v")
        }
    }

    @Test func crossInstanceWritesSerialize() async throws {
        let directory = try makeEncryptedTempDir()
        let writers = 4
        let perWriter = 15
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    let provider = makeTestProvider(directory: directory)
                    for index in 0..<perWriter {
                        try provider.set(item: "w\(writer)-\(index)", value: "v")
                    }
                }
            }
            try await group.waitForAll()
        }
        let stored = try makeTestProvider(directory: directory).list()
        #expect(stored.count == writers * perWriter)
        for entry in stored {
            #expect(try makeTestProvider(directory: directory).get(item: entry.id) == "v")
        }
    }

    @Test func lockFailureFailsClosed() throws {
        let directory = try makeEncryptedTempDir()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".secrets-encrypted.json.lock"),
            withIntermediateDirectories: false
        )
        let provider = makeTestProvider(directory: directory)
        #expect(throws: EncryptedSecretsStoreError.storeUnwritable) {
            try provider.set(item: "k", value: "v")
        }
    }
}
