import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import RVDomain
import RVFileStore
import Testing
@testable import RVIsolation

// MARK: - Helpers

/// Deterministic xorshift RNG for seeded fuzz (D's pattern): fixed seeds
/// make every run replay the same inputs, so a failure reproduces by
/// re-running the suite.
private struct XorShift64: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
}

private func makeAuthTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

private func authControlDir(in dataDir: URL) -> URL {
    dataDir.appendingPathComponent("server-control")
}

private func writeAuthFile(
    at control: URL, name: String = "auth.json", contents: String, mode: Int = 0o600
) throws {
    try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
    let url = control.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func modeBits(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
}

private func requireAuthSuccess(_ result: Result<MCPCallerToken, MCPServerAuthError>) throws -> MCPCallerToken {
    switch result {
    case .success(let token):
        return token
    case .failure(let error):
        throw error
    }
}

private func requireAuthFailure(_ result: Result<MCPCallerToken, MCPServerAuthError>) throws -> MCPServerAuthError {
    switch result {
    case .success:
        throw MCPServerAuthError.persistFailed
    case .failure(let error):
        return error
    }
}

@Suite("MCPServerAuth")
struct MCPServerAuthTests {
    // MARK: - Paths (oracle auth.ts resolveExecutorDataDir / localAuthTokenPath)

    @Test func resolveDataDirectoryNilUsesHomeExecutor() {
        #expect(MCPServerAuth.resolveDataDirectory(executorDataDir: nil, homeDirectory: "/home/u") == "/home/u/.executor")
    }

    @Test func resolveDataDirectoryBlankCountsAsUnset() {
        #expect(MCPServerAuth.resolveDataDirectory(executorDataDir: "", homeDirectory: "/h") == "/h/.executor")
        #expect(MCPServerAuth.resolveDataDirectory(executorDataDir: "  \n ", homeDirectory: "/h") == "/h/.executor")
    }

    @Test func resolveDataDirectoryAbsolutePassesThrough() {
        #expect(
            MCPServerAuth.resolveDataDirectory(executorDataDir: "/var/lib/x", homeDirectory: "/h") == "/var/lib/x"
        )
    }

    @Test func resolveDataDirectoryAbsoluteStandardizesDotDot() {
        #expect(
            MCPServerAuth.resolveDataDirectory(executorDataDir: "/var/lib/../lib2", homeDirectory: "/h")
                == "/var/lib2"
        )
    }

    @Test func resolveDataDirectoryRelativeJoinsCurrentDirectory() {
        #expect(
            MCPServerAuth.resolveDataDirectory(
                executorDataDir: "rel/dir", homeDirectory: "/h", currentDirectory: "/cwd"
            ) == "/cwd/rel/dir"
        )
    }

    @Test func resolveDataDirectoryTildeStaysLiteralLikeNodeResolve() {
        #expect(
            MCPServerAuth.resolveDataDirectory(
                executorDataDir: "~/x", homeDirectory: "/h", currentDirectory: "/cwd"
            ) == "/cwd/~/x"
        )
    }

    @Test func resolveDataDirectoryTrimsPadding() {
        #expect(
            MCPServerAuth.resolveDataDirectory(executorDataDir: "  /tmp/x  ", homeDirectory: "/h") == "/tmp/x"
        )
    }

    @Test func defaultDataDirectoryAgreesWithPureResolve() {
        let expected = MCPServerAuth.resolveDataDirectory(
            executorDataDir: ProcessInfo.processInfo.environment["EXECUTOR_DATA_DIR"],
            homeDirectory: NSHomeDirectory()
        )
        #expect(MCPServerAuth.defaultDataDirectory() == expected)
        #expect(MCPServerAuth.defaultDataDirectory().isEmpty == false)
    }

    @Test func tokenPathIsServerControlAuthJSON() {
        #expect(MCPServerAuth.tokenPath(dataDirectory: "/d") == "/d/server-control/auth.json")
        #expect(MCPServerAuth.controlDirectory(dataDirectory: "/d") == "/d/server-control")
    }

    // MARK: - Base64url + mint (oracle auth.ts mintToken = randomBytes(32).base64url)

    @Test func base64URLVectors() {
        #expect(MCPServerAuth.base64URLEncoded(Data()) == "")
        #expect(MCPServerAuth.base64URLEncoded(Data([0xFB])) == "-w")
        #expect(MCPServerAuth.base64URLEncoded(Data([0xFF, 0xFF, 0xFF])) == "____")
        #expect(MCPServerAuth.base64URLEncoded(Data("Hello".utf8)) == "SGVsbG8")
        #expect(MCPServerAuth.base64URLEncoded(Data([0x00, 0x10, 0x83])) == "ABCD")
    }

    @Test func mintTokenIs43Base64URLChars() {
        let token = MCPServerAuth.mintToken()
        #expect(token.rawValue.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(token.rawValue.allSatisfy({ allowed.contains($0) }))
    }

    @Test func mintTokenDecodesTo32Bytes() throws {
        let decoded = try #require(decodeBase64URL(MCPServerAuth.mintToken().rawValue))
        #expect(decoded.count == 32)
    }

    @Test func mintTokenNeverRepeatsAcross100Mints() {
        let minted = Set((0..<100).map { _ in MCPServerAuth.mintToken().rawValue })
        #expect(minted.count == 100)
    }

    @Test func mintTokenNeverLogsRawValue() {
        #expect(MCPServerAuth.mintToken().description == "[redacted-caller-token]")
    }

    // MARK: - normalizeCredential (oracle serve-shared.ts:27)

    @Test func normalizeCredentialMatrix() {
        #expect(MCPServerAuth.normalizeCredential(nil) == nil)
        #expect(MCPServerAuth.normalizeCredential("") == nil)
        #expect(MCPServerAuth.normalizeCredential("  \t\n ") == nil)
        #expect(MCPServerAuth.normalizeCredential("tok") == "tok")
        #expect(MCPServerAuth.normalizeCredential("  tok  ") == "tok")
        #expect(MCPServerAuth.normalizeCredential("a b") == "a b")
        #expect(MCPServerAuth.normalizeCredential("\u{A0}a\u{A0}") == "a")
        #expect(MCPServerAuth.normalizeCredential("\u{85}a\u{85}") == "\u{85}a\u{85}")
    }

    // MARK: - timingSafeEqual (oracle serve-shared.ts:32 safeEqual)

    @Test func timingSafeEqualAcceptsIdentical() {
        #expect(MCPServerAuth.timingSafeEqual("abc", "abc"))
        #expect(MCPServerAuth.timingSafeEqual("", ""))
        #expect(MCPServerAuth.timingSafeEqual(String(repeating: "z", count: 10_000), String(repeating: "z", count: 10_000)))
    }

    @Test(arguments: ["xbc", "axc", "abx"]) func timingSafeEqualRejectsSingleByteDiff(candidate: String) {
        #expect(MCPServerAuth.timingSafeEqual(candidate, "abc") == false)
        #expect(MCPServerAuth.timingSafeEqual("abc", candidate) == false)
    }

    @Test func timingSafeEqualRejectsLengthDiffs() {
        #expect(MCPServerAuth.timingSafeEqual("abc", "abcd") == false)
        #expect(MCPServerAuth.timingSafeEqual("abcd", "abc") == false)
        #expect(MCPServerAuth.timingSafeEqual("", "a") == false)
        #expect(MCPServerAuth.timingSafeEqual("a", "") == false)
        #expect(MCPServerAuth.timingSafeEqual("abc", "abcabc") == false)
    }

    @Test func timingSafeEqualComparesUTF8BytesNotScalars() {
        #expect(MCPServerAuth.timingSafeEqual("\u{E9}", "\u{E9}"))
        #expect(MCPServerAuth.timingSafeEqual("\u{E9}", "e\u{301}") == false)
    }

    @Test func separatorScalarsMatchJSWhitespaceSet() throws {
        let separators: [UInt32] = [
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
            0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
            0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
            0xFEFF,
        ]
        for value in separators {
            let scalar = try #require(UnicodeScalar(value))
            #expect(MCPServerAuth.isSeparatorScalar(scalar))
            #expect(MCPServerAuth.isSeparatorWhitespace(Character(scalar)))
        }
    }

    @Test func separatorScalarsExcludeNearMisses() throws {
        for value: UInt32 in [0x00, 0x41, 0x85, 0x180E] {
            let scalar = try #require(UnicodeScalar(value))
            #expect(MCPServerAuth.isSeparatorScalar(scalar) == false)
        }
        #expect(MCPServerAuth.isSeparatorWhitespace("a") == false)
        #expect(MCPServerAuth.isSeparatorWhitespace(" ") == true)
    }

    @Test func separatorWhitespaceRejectsMultiScalarGraphemes() {
        let combined: Character = "e\u{301}"
        #expect(combined.unicodeScalars.count == 2)
        #expect(MCPServerAuth.isSeparatorWhitespace(combined) == false)
    }

    @Test func jsTrimmedMatrix() {
        #expect(MCPServerAuth.jsTrimmed("") == "")
        #expect(MCPServerAuth.jsTrimmed("   ") == "")
        #expect(MCPServerAuth.jsTrimmed("  a  ") == "a")
        #expect(MCPServerAuth.jsTrimmed("\u{A0}a\u{A0}") == "a")
        #expect(MCPServerAuth.jsTrimmed("a\u{A0}b") == "a\u{A0}b")
        #expect(MCPServerAuth.jsTrimmed("\u{2029}a\u{2029}") == "a")
        #expect(MCPServerAuth.jsTrimmed("\u{2029}a\u{2029}b\u{2029}") == "a\u{2029}b")
    }

    // MARK: - bearerToken (oracle /^Bearer\\s+(.+)$/i + trim)

    @Test func bearerTokenParsesAndTrims() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer abc") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer   abc   ") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\tabc") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer \t abc \t ") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\u{A0}b") == "a\u{A0}b")
    }

    @Test func bearerTokenSchemeIsCaseInsensitive() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "bearer abc") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "BEARER abc") == "abc")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "BeArEr abc") == "abc")
    }

    @Test func bearerTokenRejectsMalformed() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: nil) == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer ") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer    ") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Basic abcdef") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "BearerX tok") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: " Bearer abc") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bear abc") == nil)
    }

    @Test func bearerTokenRejectsLineTerminatorsInCapture() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\nb") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\rb") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\u{2028}b") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\u{2029}b") == nil)
    }

    @Test func bearerTokenKeepsNELLikeOracleTrim() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer a\u{85}") == "a\u{85}")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer \u{85}") == "\u{85}")
    }

    @Test func bearerTokenKeepsUnicodeAndCombiningMarks() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer \u{E9}") == "\u{E9}")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer e\u{301}") == "e\u{301}")
    }

    @Test func bearerTokenSeparatorsBeyondSpace() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\u{A0}a") == "a")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\u{2029}a") == "a")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\u{2028}a") == "a")
    }

    @Test func timingSafeEqualAgreesWithByteEqualityOnSeededPairs() {
        // Seeded (XorShift64, D's pattern): the same 1,000 pairs every run.
        // The oracle is UTF-8 byte equality — NOT `==`, which folds
        // canonically-equal-but-byte-differing pairs the comparator must
        // reject.
        var rng = XorShift64(state: 0x51AB_3E77_90CD_42F1)
        let alphabet = Array("abcdefghij0123456789\u{E9}\u{301}-\t ")
        for _ in 0..<1_000 {
            let left = String(
                (0..<Int(rng.next() % 25)).map { _ in
                    alphabet[Int(rng.next() % UInt64(alphabet.count))]
                }
            )
            let right = rng.next() % 2 == 0 ? left : String(left.reversed())
            #expect(
                MCPServerAuth.timingSafeEqual(left, right)
                    == (Array(left.utf8) == Array(right.utf8))
            )
        }
    }

    @Test func timingSafeEqualIsByteEqualityNotCanonicalEquality() {
        // "e\u{301}\u{E9}" reversed is canonically equal but byte-differing:
        // `==` says true while the byte comparator must say false. The old
        // `==` oracle asserted true here — wrong.
        let left = "e\u{301}\u{E9}"
        let right = String(left.reversed())
        #expect(left == right)
        #expect(Array(left.utf8) != Array(right.utf8))
        #expect(MCPServerAuth.timingSafeEqual(left, right) == false)
    }

    // MARK: - isAuthorized / makeIsAuthorized (oracle hasBearerToken / makeIsAuthorized)

    @Test func isAuthorizedAcceptsMatchingBearer() {
        let token = MCPServerAuth.mintToken()
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "Bearer \(token.rawValue)", token: token))
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "bearer   \(token.rawValue)  ", token: token))
    }

    @Test func isAuthorizedRejectsMissingOrWrong() {
        let token = MCPServerAuth.mintToken()
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: nil, token: token) == false)
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "Bearer wrong", token: token) == false)
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "Basic \(token.rawValue)", token: token) == false)
        #expect(
            MCPServerAuth.isAuthorized(authorizationHeader: "Bearer \(token.rawValue)x", token: token) == false
        )
    }

    @Test func makeIsAuthorizedBuildsWorkingGate() {
        let token = MCPServerAuth.mintToken()
        let gate = MCPServerAuth.makeIsAuthorized(token: token)
        #expect(gate("Bearer \(token.rawValue)"))
        #expect(gate("Bearer wrong") == false)
        #expect(gate(nil) == false)
    }

    // MARK: - decode (strict document triage)

    @Test func decodeAcceptsValidDocument() {
        let verdict = MCPServerAuth.decode(Data("{\"token\":\"abc\"}".utf8))
        #expect(verdict == .valid(MCPCallerToken(rawValue: "abc")))
    }

    // Deliberate divergence: the oracle's `readToken` ignores unknown
    // fields, but strict triage treats them as tampering and fails closed
    // instead (see `MCPServerAuth.decode`).
    @Test func decodeRejectsUnknownFieldsAsInvalid() {
        #expect(MCPServerAuth.decode(Data("{\"token\":\"abc\",\"x\":1}".utf8)) == .invalid)
        #expect(MCPServerAuth.decode(Data("{\"x\":1}".utf8)) == .invalid)
    }

    @Test func decodeRemintsUnparseableDocuments() {
        #expect(MCPServerAuth.decode(Data("not json".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("\"str\"".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("[1]".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("123".utf8)) == .remint)
    }

    @Test func decodeRemintsMissingOrEmptyOrNonStringToken() {
        #expect(MCPServerAuth.decode(Data("{}".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("{\"token\":\"\"}".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("{\"token\":1}".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("{\"token\":null}".utf8)) == .remint)
        #expect(MCPServerAuth.decode(Data("{\"token\":{}}".utf8)) == .remint)
    }

    // MARK: - encode / isStorableToken

    @Test func encodeMatchesOraclePrettyShape() {
        let bytes = MCPServerAuth.encode(MCPCallerToken(rawValue: "abc"))
        #expect(String(data: bytes, encoding: .utf8) == "{\n  \"token\": \"abc\"\n}\n")
    }

    @Test func isStorableTokenAllowsBase64URLOnly() {
        #expect(MCPServerAuth.isStorableToken(MCPCallerToken(rawValue: "Ab3-_")) == true)
        #expect(MCPServerAuth.isStorableToken(MCPServerAuth.mintToken()) == true)
        #expect(MCPServerAuth.isStorableToken(MCPCallerToken(rawValue: "")) == false)
        #expect(MCPServerAuth.isStorableToken(MCPCallerToken(rawValue: "a\"b")) == false)
        #expect(MCPServerAuth.isStorableToken(MCPCallerToken(rawValue: "a b")) == false)
        #expect(MCPServerAuth.isStorableToken(MCPCallerToken(rawValue: "a+b/")) == false)
    }

    // MARK: - loadOrMint (oracle loadOrMintLocalAuthToken)

    @Test func loadOrMintMints0600FileOnFirstRun() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(token.rawValue.count == 43)
        let file = authControlDir(in: dir).appendingPathComponent("auth.json")
        #expect(try modeBits(of: file) == 0o600)
        #expect(try modeBits(of: authControlDir(in: dir)) == 0o700)
        let stored = try String(contentsOf: file, encoding: .utf8)
        #expect(stored == "{\n  \"token\": \"\(token.rawValue)\"\n}\n")
    }

    @Test func loadOrMintIsStableAcrossRestarts() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        let second = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(first == second)
    }

    @Test func loadOrMintSelfHealsGarbageFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthFile(at: authControlDir(in: dir), contents: "garbage{{{")
        let token = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(token.rawValue.count == 43)
        let again = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(again == token)
    }

    @Test func loadOrMintSelfHealsTokenlessDocument() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthFile(at: authControlDir(in: dir), contents: "{\"token\":\"\"}")
        let token = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(token.rawValue.isEmpty == false)
    }

    // Deliberate divergence (same as `decodeRejectsUnknownFieldsAsInvalid`):
    // the oracle reads through unknown fields while strict triage fails
    // closed and preserves the file untouched.
    @Test func loadOrMintFailsClosedOnUnknownFieldsAndPreservesFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let contents = "{\"token\":\"abc\",\"unknown\":1}"
        try writeAuthFile(at: authControlDir(in: dir), contents: contents)
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .invalidDocument)
        let file = authControlDir(in: dir).appendingPathComponent("auth.json")
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)
    }

    @Test func loadOrMintFailsClosedOnWorldReadableFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthFile(at: authControlDir(in: dir), contents: "{\"token\":\"abc\"}", mode: 0o644)
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .unsafeLocation)
    }

    @Test func loadOrMintFailsClosedOnUnreadableFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}", mode: 0o000)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: control.appendingPathComponent("auth.json").path
            )
        }
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .inaccessible)
    }

    @Test func loadOrMintFailsClosedOnSymlinkedFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let target = control.appendingPathComponent("real.json")
        try "{\"token\":\"abc\"}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(
            at: control.appendingPathComponent("auth.json"), withDestinationURL: target
        )
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .inaccessible)
    }

    @Test func loadOrMintFailsClosedOnGroupWritableDirectory() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}")
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: control.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path) }
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .unsafeLocation)
    }

    @Test func loadOrMintFailsClosedOnFileBlockingControlDirectory() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: authControlDir(in: dir), atomically: true, encoding: .utf8)
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .inaccessible)
    }

    @Test func loadOrMintFailsClosedOnOversizedFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthFile(at: authControlDir(in: dir), contents: String(repeating: "x", count: 5_000))
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .oversized)
    }

    @Test func loadOrMintFailsWhenParentIsAFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("x")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: blocker.appendingPathComponent("y").path))
        #expect(error == .inaccessible)
    }

    @Test func loadOrMintFailsPersistWhenReadOnlyAfterRemint() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "garbage")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: control.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path) }
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(error == .persistFailed)
    }

    @Test func loadOrMintFailsWhenDataDirectoryIsAFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blocker")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let error = try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: file.path))
        #expect(error == .inaccessible)
    }

    @Test func persistFailsWhenDataDirectoryIsAFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blocker")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let result = MCPServerAuth.persist(dataDirectory: file.path, token: MCPServerAuth.mintToken())
        #expect(try requireAuthFailure(result) == .persistFailed)
    }

    // MARK: - rotate (oracle rotateLocalAuthToken)

    @Test func rotateMintsWhenMissing() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
        #expect(token.rawValue.count == 43)
    }

    @Test func rotateInvalidatesOldToken() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        let new = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
        #expect(new != old)
        let loaded = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(loaded == new)
    }

    @Test func rotateRepairsWorldReadableFileTo0600() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthFile(at: authControlDir(in: dir), contents: "{\"token\":\"abc\"}", mode: 0o644)
        let token = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
        let file = authControlDir(in: dir).appendingPathComponent("auth.json")
        #expect(try modeBits(of: file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"token\": \"\(token.rawValue)\"\n}\n")
    }

    @Test func rotateFailsWhenReadOnly() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: control.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path) }
        let error = try requireAuthFailure(MCPServerAuth.rotate(dataDirectory: dir.path))
        #expect(error == .persistFailed)
    }

    @Test func rotateFailsOnGroupWritableDirectory() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}")
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: control.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path) }
        let error = try requireAuthFailure(MCPServerAuth.rotate(dataDirectory: dir.path))
        #expect(error == .unsafeLocation)
    }

    // MARK: - persist + syscall helpers (direct)

    @Test func persistRejectsUnstorableToken() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = MCPServerAuth.persist(dataDirectory: dir.path, token: MCPCallerToken(rawValue: "a\"b"))
        #expect(try requireAuthFailure(result) == .persistFailed)
    }

    @Test func openControlDirectoryMatrix() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let good = MCPServerAuth.openControlDirectory(at: control.path)
        #expect(good >= 0)
        if good >= 0 { close(good) }
        #expect(MCPServerAuth.openControlDirectory(at: control.appendingPathComponent("nope").path) < 0)
        let blocker = dir.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        #expect(MCPServerAuth.openControlDirectory(at: blocker.path) < 0)
    }

    @Test func createControlDirectoryMatrix() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = dir.appendingPathComponent("a/b").path
        #expect(MCPServerAuth.createControlDirectory(at: fresh) == true)
        #expect(MCPServerAuth.createControlDirectory(at: fresh) == true)
        let blocker = dir.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        #expect(MCPServerAuth.createControlDirectory(at: blocker.appendingPathComponent("c").path) == false)
    }

    @Test func controlDirectoryIsTrustedMatrix() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        #expect(MCPServerAuth.controlDirectoryIsTrusted(fd) == true)
        #expect(MCPServerAuth.controlDirectoryIsTrusted(-1) == false)
        #expect(MCPServerAuth.controlDirectoryIsTrusted(fd, ownerUID: getuid() + 1) == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: control.path)
        #expect(MCPServerAuth.controlDirectoryIsTrusted(fd) == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let file = dir.appendingPathComponent("f")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let fileFD = file.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        #expect(fileFD >= 0)
        defer { if fileFD >= 0 { close(fileFD) } }
        #expect(MCPServerAuth.controlDirectoryIsTrusted(fileFD) == false)
    }

    @Test func replaceTokenFileMatrix() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        let bytes = Data("{\"token\":\"abc\"}\n".utf8)
        #expect(MCPServerAuth.replaceTokenFile(bytes: bytes, dirFD: fd) == true)
        #expect(try modeBits(of: control.appendingPathComponent("auth.json")) == 0o600)
        #expect(MCPServerAuth.replaceTokenFile(bytes: bytes, dirFD: -1) == false)
        #expect(MCPServerAuth.replaceTokenFile(bytes: bytes, dirFD: fd, chmod: { _ in false }) == false)
    }

    @Test func replaceTokenFileFailsWhenLiveIsADirectory() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        try FileManager.default.createDirectory(
            at: control.appendingPathComponent("auth.json"), withIntermediateDirectories: false
        )
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        defer { if fd >= 0 { close(fd) } }
        #expect(MCPServerAuth.replaceTokenFile(bytes: Data("x".utf8), dirFD: fd) == false)
    }

    @Test func repairLiveFileModeMatrix() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}", mode: 0o644)
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        defer { if fd >= 0 { close(fd) } }
        #expect(MCPServerAuth.repairLiveFileMode(dirFD: fd, chmod: { _ in true }) == true)
        #expect(try modeBits(of: control.appendingPathComponent("auth.json")) == 0o644)
        #expect(MCPServerAuth.repairLiveFileMode(dirFD: -1, chmod: { _ in true }) == false)
        #expect(MCPServerAuth.repairLiveFileMode(dirFD: fd, chmod: { _ in false }) == false)
    }

    @Test func repairLiveFileModeRepairsWithRealChmod() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try writeAuthFile(at: control, contents: "{\"token\":\"abc\"}", mode: 0o644)
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        defer { if fd >= 0 { close(fd) } }
        #expect(MCPServerAuth.replaceTokenFile(bytes: Data("{\"token\":\"z\"}\n".utf8), dirFD: fd) == true)
        #expect(try modeBits(of: control.appendingPathComponent("auth.json")) == 0o600)
    }

    @Test func repairLiveFileModeRefusesSymlinkedLiveFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let target = control.appendingPathComponent("real.json")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: control.appendingPathComponent("auth.json"), withDestinationURL: target
        )
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        defer { if fd >= 0 { close(fd) } }
        #expect(MCPServerAuth.repairLiveFileMode(dirFD: fd, chmod: { _ in true }) == false)
    }

    // MARK: - Stress

    @Test func repeatedLoadsStayStable() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        for _ in 0..<50 {
            #expect(try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == first)
        }
    }

    @Test func repeatedRotatesStayUnique() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var seen = Set<String>()
        for _ in 0..<20 {
            let token = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
            #expect(seen.contains(token.rawValue) == false)
            seen.insert(token.rawValue)
        }
        let loaded = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(seen.contains(loaded.rawValue))
    }

    @Test func bearerParserNeverCrashesOnSeededInput() {
        // Seeded (XorShift64): the same 500 inputs every run.
        var rng = XorShift64(state: 0xBEA4_10CE_55ED_7A11)
        let alphabet = Array("Bearer \t\n\rabcxYZ019_-+=/.,:;\"'\\")
        for _ in 0..<500 {
            let input = String(
                (0..<Int(rng.next() % 33)).map { _ in
                    alphabet[Int(rng.next() % UInt64(alphabet.count))]
                }
            )
            let parsed = MCPServerAuth.bearerToken(fromAuthorizationHeader: input)
            if let parsed {
                #expect(parsed.isEmpty == false)
                #expect(parsed.contains("\n") == false)
                #expect(parsed.contains("\r") == false)
            }
        }
    }

    // MARK: - Review hardening (X1-N)

    @Test func rotateHealsSymlinkedTokenFile() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: control.path)
        let outside = dir.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: control.appendingPathComponent("auth.json"), withDestinationURL: outside
        )
        #expect(try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == .inaccessible)
        let token = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
        let file = control.appendingPathComponent("auth.json")
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        #expect(values.isSymbolicLink == false)
        #expect(values.isRegularFile == true)
        #expect(try modeBits(of: file) == 0o600)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
        #expect(try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == token)
    }

    @Test func symlinkedControlDirectoryFailsClosed() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: authControlDir(in: dir), withDestinationURL: real)
        #expect(try requireAuthFailure(MCPServerAuth.rotate(dataDirectory: dir.path)) == .persistFailed)
        #expect(try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == .inaccessible)
    }

    @Test func concurrentRotatesAndLoadsStayConsistent() async throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.path
        let initial = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir))
        let pairs = try await withThrowingTaskGroup(of: (Bool, String).self) { group in
            for _ in 0..<10 {
                group.addTask {
                    (true, try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dataDir)).rawValue)
                }
            }
            for _ in 0..<20 {
                group.addTask {
                    (false, try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir)).rawValue)
                }
            }
            var collected: [(Bool, String)] = []
            for try await pair in group { collected.append(pair) }
            return collected
        }
        let rotates = pairs.filter({ $0.0 }).map({ $0.1 })
        let loads = pairs.filter({ $0.0 == false }).map({ $0.1 })
        #expect(rotates.count == 10)
        #expect(loads.count == 20)
        // Ten distinct rotates; every load observed one complete minted
        // document (the initial token or a rotate). A torn read would remint
        // a value outside the minted set and fail the subset check below.
        #expect(Set(rotates).count == 10)
        let minted = Set(rotates + [initial.rawValue])
        #expect(loads.allSatisfy({ minted.contains($0) }))
        let live = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir))
        #expect(minted.contains(live.rawValue))
    }

    @Test func concurrentFirstBootMintsAllSucceed() async throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dataDir = dir.path
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir)).rawValue }
            }
            var collected: [String] = []
            for try await value in group { collected.append(value) }
            return collected
        }
        #expect(tokens.count == 10)
        #expect(tokens.allSatisfy({ $0.count == 43 }))
        let live = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir))
        #expect(tokens.contains(live.rawValue))
        #expect(try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dataDir)) == live)
        let file = authControlDir(in: dir).appendingPathComponent("auth.json")
        #expect(try modeBits(of: file) == 0o600)
    }

    @Test func abandonedStageLeavesLiveTokenIntact() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = authControlDir(in: dir)
        let before = "{\"token\":\"abc\"}"
        try writeAuthFile(at: control, contents: before)
        let fd = MCPServerAuth.openControlDirectory(at: control.path)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        // Simulate a crash after staging but before commit: stage a temp,
        // then abandon it exactly as a dead process would.
        let staged = OwnerOnlyFileWrite.stage(
            bytes: Data("{\"token\":\"zzz\"}\n".utf8), fileName: "auth.json", tag: "auth",
            inDirectory: fd, policy: .all, attempts: 8
        )
        let orphan = try #require(staged)
        close(orphan.fd)
        let loaded = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        #expect(loaded == MCPCallerToken(rawValue: "abc"))
        let file = control.appendingPathComponent("auth.json")
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
        #expect(try modeBits(of: control.appendingPathComponent(orphan.name)) == 0o600)
    }

    @Test func loosenedPermissionsFailClosedThenRotateRehardens() throws {
        let dir = try makeAuthTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path))
        let file = authControlDir(in: dir).appendingPathComponent("auth.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try requireAuthFailure(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == .unsafeLocation)
        let rotated = try requireAuthSuccess(MCPServerAuth.rotate(dataDirectory: dir.path))
        #expect(rotated != first)
        #expect(try modeBits(of: file) == 0o600)
        #expect(try requireAuthSuccess(MCPServerAuth.loadOrMint(dataDirectory: dir.path)) == rotated)
    }

    @Test func bearerTokenHandlesEmptyAndOversized() {
        let huge = String(repeating: "a", count: 100_000)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer \(huge)") == huge)
        let token = MCPCallerToken(rawValue: huge)
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "Bearer \(huge)", token: token))
        #expect(MCPServerAuth.isAuthorized(authorizationHeader: "Bearer \(huge)x", token: token) == false)
        #expect(
            MCPServerAuth.isAuthorized(authorizationHeader: "Bearer x", token: MCPCallerToken(rawValue: "")) == false
        )
    }

    @Test func bearerTokenPrefixConfusionMatrix() {
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearers tok") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearertok") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "BearerX tok") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "bearerx tok") == nil)
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "BEARER\u{2003}tok") == "tok")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\u{0B}tok") == "tok")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "Bearer\u{0C}tok") == "tok")
        #expect(MCPServerAuth.bearerToken(fromAuthorizationHeader: "bearer\u{FEFF}tok") == "tok")
    }

    @Test func timingSafeEqualExhaustiveOverSmallAlphabet() {
        // Oracle is UTF-8 byte equality, NOT `==`: `"\u{E9}" == "e\u{301}"` is
        // true under canonical equivalence while the bytes differ, and the
        // timing-safe compare must follow the bytes (see also
        // `timingSafeEqualComparesUTF8BytesNotScalars`).
        let values = ["", "a", "b", "aa", "ab", "ba", "\0", "a\0", "\0a", "abc", "abcd", "\u{E9}", "e\u{301}"]
        for left in values {
            for right in values {
                #expect(MCPServerAuth.timingSafeEqual(left, right) == left.utf8.elementsEqual(right.utf8))
            }
        }
        let prefix = String(repeating: "a", count: 10_000)
        #expect(MCPServerAuth.timingSafeEqual(prefix + "x", prefix + "y") == false)
        #expect(MCPServerAuth.timingSafeEqual(prefix + "y", prefix + "x") == false)
        #expect(MCPServerAuth.timingSafeEqual(prefix + "x", prefix + "x"))
        #expect(MCPServerAuth.timingSafeEqual("", String(repeating: "b", count: 10_000)) == false)
    }
}
