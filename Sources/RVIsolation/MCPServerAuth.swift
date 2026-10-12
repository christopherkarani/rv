#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore

/// Local MCP server Bearer [REDACTED] (X1-N).
///
/// Ports Executor `apps/local/src/auth.ts` (`resolveExecutorDataDir`,
/// `localAuthTokenPath`, `loadOrMintLocalAuthToken`, `rotateLocalAuthToken`)
/// and the `serve-shared.ts` credential seam (`normalizeCredential`,
/// `safeEqual`, `hasBearerToken`, `makeIsAuthorized`).
///
/// Oracle behaviors pinned by `apps/local/src/serve.test.ts`
/// ("mints and persists a 0600 auth.json when no token is supplied") and
/// `apps/local/src/serve-shared.test.ts` ("accepts a matching Bearer [REDACTED]
/// "rejects a missing or wrong token"). Every ported behavior cites its
/// oracle in the member docs below.
///
/// Two deliberate divergences from the oracle:
/// - Reads enforce the owner-only discipline (dir-fd, `NOFOLLOW`, `S_IFREG`,
///   owner check) instead of the oracle's plain `readFileSync`: a
///   group/world-readable token file fails closed instead of loading.
/// - A parseable file that carries a usable token plus unknown fields fails
///   closed (`invalidDocument`) instead of loading (the oracle ignores
///   unknown members). The file is preserved, never overwritten: only files
///   that provably carry no usable token are self-healed with a fresh mint.
public enum MCPServerAuth {
    /// Token-file name inside the control directory (`auth.ts`: `auth.json`).
    public static let fileName = "auth.json"
    /// Control-directory name inside the data directory (`server-control`).
    public static let controlDirectoryName = "server-control"
    /// Minted entropy per token: 32 bytes = 256 bits (`randomBytes(32)`).
    public static let tokenBytes = 32
    /// Largest token file accepted on read. The document is one short line;
    /// anything larger is foreign material that fails closed.
    public static let maximumBytes = 4_096

    // MARK: - Paths (auth.ts: resolveExecutorDataDir, localAuthTokenPath)

    /// Resolves the data directory: `EXECUTOR_DATA_DIR` when set and
    /// non-blank, else `~/.executor` under `homeDirectory`, absolutized
    /// against `currentDirectory` exactly like Node `resolve()`.
    ///
    /// Oracle: `resolve(process.env.EXECUTOR_DATA_DIR ?? join(homedir(),
    /// ".executor"))`. Divergence: a blank value counts as unset (the oracle
    /// would resolve an empty string to the working directory, a footgun
    /// for a secret file). Tildes are NOT expanded, matching Node.
    public static func resolveDataDirectory(
        executorDataDir: String?,
        homeDirectory: String,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String {
        let trimmed = executorDataDir?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty == false {
            if trimmed.hasPrefix("/") {
                return URL(fileURLWithPath: trimmed).standardizedFileURL.path
            }
            return URL(fileURLWithPath: currentDirectory).appendingPathComponent(trimmed)
                .standardizedFileURL.path
        }
        return URL(fileURLWithPath: homeDirectory).appendingPathComponent(".executor").standardizedFileURL.path
    }

    /// Resolves the data directory from the live process environment.
    /// Thin boundary over `resolveDataDirectory`, which carries the logic.
    public static func defaultDataDirectory() -> String {
        Self.resolveDataDirectory(
            executorDataDir: ProcessInfo.processInfo.environment["EXECUTOR_DATA_DIR"],
            homeDirectory: NSHomeDirectory()
        )
    }

    /// Control-directory path for a data directory.
    static func controlDirectory(dataDirectory: String) -> String {
        URL(fileURLWithPath: dataDirectory).appendingPathComponent(controlDirectoryName).path
    }

    /// Absolute token-file path for a data directory.
    /// Oracle: `localAuthTokenPath` (`<dataDir>/server-control/auth.json`).
    public static func tokenPath(dataDirectory: String) -> String {
        URL(fileURLWithPath: controlDirectory(dataDirectory: dataDirectory)).appendingPathComponent(fileName).path
    }

    // MARK: - Mint (auth.ts: mintToken = randomBytes(32).base64url)

    /// Base64url-encodes bytes with no padding, matching Node
    /// `randomBytes(32).toString("base64url")`.
    static func base64URLEncoded(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Mints a fresh 256-bit caller token. The value is 43 base64url chars
    /// decoding to exactly 32 random bytes.
    public static func mintToken() -> MCPCallerToken {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<tokenBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return MCPCallerToken(rawValue: base64URLEncoded(bytes))
    }

    // MARK: - Credential seam (serve-shared.ts)

    /// Trims JS-whitespace (`WhiteSpace` + `LineTerminator`, the exact set
    /// JS `String.trim` removes) from both ends. Hand-rolled so the bearer
    /// path matches the oracle regex `/^Bearer\s+(.+)$/i` scalar-for-scalar
    /// instead of inheriting Foundation's trim set (which also strips NEL).
    static func jsTrimmed(_ value: String) -> String {
        let leading = value.drop(while: Self.isSeparatorWhitespace)
        var end = leading.endIndex
        while end > leading.startIndex, Self.isSeparatorWhitespace(leading[leading.index(before: end)]) {
            end = leading.index(before: end)
        }
        return String(leading[..<end])
    }

    /// True for the single scalars JS `\s` matches: TAB, LF, VT, FF, CR,
    /// SP, NBSP, ZWNBSP, Ogham, U+2000-U+200A, LS, PS, narrow NBSP, medium
    /// mathematical space, and ideographic space. Multi-scalar graphemes
    /// are never separators.
    static func isSeparatorWhitespace(_ scalar: Character) -> Bool {
        guard scalar.unicodeScalars.count == 1 else { return false }
        return Self.isSeparatorScalar(scalar.unicodeScalars[scalar.unicodeScalars.startIndex])
    }

    /// True for the scalar values JS `\s` matches (see
    /// `isSeparatorWhitespace`). Notably excludes NEL (U+0085) and
    /// Mongolian vowel separator (U+180E), which JS does not match.
    static func isSeparatorScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
            0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
            0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
            0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Normalizes an optional credential: trims JS-whitespace, empties to
    /// nil. Oracle: `normalizeCredential` (serve-shared.ts:27).
    public static func normalizeCredential(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = Self.jsTrimmed(value)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    /// Constant-time string equality over UTF-8 bytes. Unlike the oracle's
    /// `safeEqual` (length check + `timingSafeEqual`, serve-shared.ts:32),
    /// this folds the length difference into the accumulator and iterates
    /// to the longer length with no early exit, so all lengths take the
    /// same shape of work. Verified by shape tests only, never timing
    /// asserts: `timingSafeEqual` must agree with `==` on every input.
    public static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = a.count ^ b.count
        let longest = max(a.count, b.count)
        for index in 0..<longest {
            let x: UInt8 = index < a.count ? a[index] : 0
            let y: UInt8 = index < b.count ? b[index] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    /// Line terminators JS `.` never matches, so the bearer capture may
    /// never contain them (`/^Bearer\s+(.+)$/` without the `s` flag).
    private static let captureTerminators: Set<UInt32> = [0x0A, 0x0D, 0x2028, 0x2029]

    /// Parses an `Authorization` header value per the oracle
    /// `hasBearerToken` (serve-shared.ts:59): `/^Bearer\s+(.+)$/i` plus
    /// trim. The scheme is case-insensitive, the separator is one or more
    /// JS-whitespace scalars, the capture is one or more non-line-
    /// terminator chars, and the capture is JS-trimmed. Anything else is
    /// nil. The returned candidate still faces `timingSafeEqual`.
    public static func bearerToken(fromAuthorizationHeader header: String?) -> String? {
        guard let header else { return nil }
        guard header.count >= 8 else { return nil }
        guard header.prefix(6).lowercased() == "bearer" else { return nil }
        let afterScheme = header.dropFirst(6)
        guard let first = afterScheme.first, Self.isSeparatorWhitespace(first) else { return nil }
        let credentials = afterScheme.drop(while: Self.isSeparatorWhitespace)
        guard credentials.isEmpty == false else { return nil }
        let captured = String(credentials)
        guard captured.unicodeScalars.allSatisfy({ Self.captureTerminators.contains($0.value) == false }) else {
            return nil
        }
        return Self.jsTrimmed(captured)
    }

    /// The request gate: a valid `Authorization: Bearer <token>` header
    /// checked with the timing-safe compare. Oracle: `hasBearerToken`
    /// (serve-shared.ts:59), pinned by serve-shared.test.ts "accepts a
    /// matching Bearer [REDACTED] a missing or wrong token".
    public static func isAuthorized(authorizationHeader: String?, token: MCPCallerToken) -> Bool {
        guard let candidate = Self.bearerToken(fromAuthorizationHeader: authorizationHeader) else { return false }
        return Self.timingSafeEqual(candidate, token.rawValue)
    }

    /// Builds the request gate for one token. Oracle: `makeIsAuthorized`
    /// (serve-shared.ts:66).
    public static func makeIsAuthorized(token: MCPCallerToken) -> @Sendable (String?) -> Bool {
        { header in Self.isAuthorized(authorizationHeader: header, token: token) }
    }

    // MARK: - Load / rotate (auth.ts: loadOrMintLocalAuthToken, rotateLocalAuthToken)

    /// Loads the stable Bearer [REDACTED] a fresh one on first
    /// run. Stable across restarts so client configs survive. Oracle:
    /// `loadOrMintLocalAuthToken` (auth.ts:64), pinned by serve.test.ts
    /// "mints and persists a 0600 auth.json when no token is supplied".
    ///
    /// A file that parses but provably carries no usable token (garbage
    /// JSON, a non-object, a missing or empty token) self-heals with a
    /// fresh mint exactly like the oracle's `readToken ?? writeToken`. A
    /// file that DOES carry a token plus unknown fields fails closed with
    /// `invalidDocument` and is left untouched.
    public static func loadOrMint(dataDirectory: String) -> Result<MCPCallerToken, MCPServerAuthError> {
        switch OwnerOnlyFile.loadBytes(
            fileName: fileName,
            from: URL(fileURLWithPath: controlDirectory(dataDirectory: dataDirectory)),
            maximumBytes: maximumBytes
        ) {
        case .success(let data):
            switch Self.decode(data) {
            case .valid(let token):
                return .success(token)
            case .remint:
                return Self.persist(dataDirectory: dataDirectory, token: Self.mintToken())
            case .invalid:
                return .failure(.invalidDocument)
            }
        case .failure(.missing):
            return Self.persist(dataDirectory: dataDirectory, token: Self.mintToken())
        case .failure(.inaccessible), .failure(.unreadable):
            // `.unreadable` (a `read(2)` failure on a validated regular
            // file) shares the `.inaccessible` outcome: the token could
            // not be obtained. One region, covered by EACCES tests.
            return .failure(.inaccessible)
        case .failure(.unsafeLocation):
            return .failure(.unsafeLocation)
        case .failure(.oversized):
            return .failure(.oversized)
        }
    }

    /// Rotates the Bearer [REDACTED] a fresh one and overwriting the
    /// file. Callers must re-advertise it and restart any running server.
    /// Oracle: `rotateLocalAuthToken` (auth.ts:72).
    public static func rotate(dataDirectory: String) -> Result<MCPCallerToken, MCPServerAuthError> {
        Self.persist(dataDirectory: dataDirectory, token: Self.mintToken())
    }

    /// Decode verdict for one token-file document.
    static func decode(_ data: Data) -> MCPServerAuthDocumentVerdict {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return .remint }
        guard let object = json as? [String: Any] else { return .remint }
        guard Set(object.keys).isSubset(of: ["token"]) else { return .invalid }
        guard let token = object["token"] as? String, token.isEmpty == false else { return .remint }
        return .valid(MCPCallerToken(rawValue: token))
    }

    /// Characters a token may contain when persisted: base64url only, so
    /// the hand-written document needs no escaping. Minted tokens always
    /// qualify; anything else fails closed instead of writing odd bytes.
    private static let storableTokenChars: Set<UnicodeScalar> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars
    )

    /// True for non-empty base64url-only token values.
    static func isStorableToken(_ token: MCPCallerToken) -> Bool {
        token.rawValue.isEmpty == false
            && token.rawValue.unicodeScalars.allSatisfy({ Self.storableTokenChars.contains($0) })
    }

    /// Encodes the `{"token": ...}` document, byte-shaped like the oracle's
    /// `writeToken` pretty print. Callers prove storability first.
    static func encode(_ token: MCPCallerToken) -> Data {
        Data("{\n  \"token\": \"\(token.rawValue)\"\n}\n".utf8)
    }

    /// Persists one token, creating the control directory on first run.
    /// Staging uses the `.all` write policy: token persistence must not
    /// silently lose writes.
    static func persist(dataDirectory: String, token: MCPCallerToken) -> Result<MCPCallerToken, MCPServerAuthError> {
        let directory = Self.controlDirectory(dataDirectory: dataDirectory)
        var dirFD = Self.openControlDirectory(at: directory)
        if dirFD < 0 {
            if Self.createControlDirectory(at: directory) {
                dirFD = Self.openControlDirectory(at: directory)
            }
            guard dirFD >= 0 else { return .failure(.persistFailed) }
        }
        defer { close(dirFD) }
        guard Self.controlDirectoryIsTrusted(dirFD) else { return .failure(.unsafeLocation) }
        guard Self.isStorableToken(token) else { return .failure(.persistFailed) }
        guard Self.replaceTokenFile(bytes: Self.encode(token), dirFD: dirFD) else {
            return .failure(.persistFailed)
        }
        return .success(token)
    }

    /// Opens the control directory, or -1. `O_NOFOLLOW` refuses symlinks.
    static func openControlDirectory(at path: String) -> Int32 {
        path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    /// Creates the control directory (parents too) with owner-only mode.
    /// True when the directory exists afterwards, whatever created it.
    static func createControlDirectory(at path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        return true
    }

    /// True for an owner-owned directory without group/other write, the
    /// write-side mirror of the read discipline. `ownerUID` is injectable
    /// so tests can fail the ownership arm without another user.
    static func controlDirectoryIsTrusted(_ dirFD: Int32, ownerUID: uid_t = getuid()) -> Bool {
        var status = stat()
        guard fstat(dirFD, &status) == 0 else { return false }
        guard status.st_uid == ownerUID else { return false }
        guard (status.st_mode & S_IFMT) == S_IFDIR else { return false }
        return (status.st_mode & 0o022) == 0
    }

    /// Stages `bytes` in a 0600 temp (`.all` policy, eight attempts with
    /// `EEXIST` retry, the same pair as the migration rewrite) and commits
    /// it over the live file, then repairs the live mode to 0600. The
    /// `chmod` seam defaults to the real `fchmod`; tests inject failure.
    static func replaceTokenFile(
        bytes: Data,
        dirFD: Int32,
        chmod: (Int32) -> Bool = { fchmod($0, 0o600) == 0 }
    ) -> Bool {
        guard
            let staged = OwnerOnlyFileWrite.stage(
                bytes: bytes, fileName: fileName, tag: "auth",
                inDirectory: dirFD, policy: .all, attempts: 8
            )
        else {
            return false
        }
        defer { close(staged.fd) }
        guard OwnerOnlyFileWrite.commit(staged: staged, as: fileName, inDirectory: dirFD) else {
            return false
        }
        return Self.repairLiveFileMode(dirFD: dirFD, chmod: chmod)
    }

    /// Post-hoc `0600` repair of the live file, mirroring the oracle's
    /// `chmodSync(path, 0o600)` covering pre-existing world-readable files.
    /// Opens with `NOFOLLOW` so a swapped-in symlink fails closed.
    static func repairLiveFileMode(dirFD: Int32, chmod: (Int32) -> Bool) -> Bool {
        let fd = fileName.withCString { openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard chmod(fd) else { return false }
        return true
    }
}

/// Load/rotate failure. Fixed labels; never paths or token material.
public enum MCPServerAuthError: Error, Sendable, Equatable, Hashable {
    /// The directory or file failed the owner-only checks.
    case unsafeLocation
    /// The directory or file could not be opened.
    case inaccessible
    /// The file exceeds the size cap.
    case oversized
    /// The file carries a token plus unknown fields. Preserved, not loaded.
    case invalidDocument
    /// The token could not be persisted.
    case persistFailed
}

/// Token-file decode verdict: load, self-heal with a fresh mint, or fail
/// closed while preserving the file.
enum MCPServerAuthDocumentVerdict: Sendable, Equatable {
    /// The file carries a usable token.
    case valid(MCPCallerToken)
    /// The file provably carries no usable token: overwrite with a mint.
    case remint
    /// The file carries a token plus unknown fields: error, keep the file.
    case invalid
}
