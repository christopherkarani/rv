import Foundation
import RVDomain
import RVFileStore

/// Step 8B.1: pending-code coordination + display projection ONLY. This file
/// is same-user writable and MUST NEVER be an authority source: there is no
/// `consume`, `hasGrant`, or `insertGranted` here by design. Spend/peek
/// authority lives in `EphemeralAllowOnceTable` (service-held memory).
/// `redeem` validates the typed code and flips the row as a projection +
/// fast-path single-use hint; the daemon's table is the authoritative
/// single-use enforcer.
public actor AllowOnceStore {
    nonisolated public let baseDirectory: URL
    private let store: FileLockedJSONLStore<AllowOnceRecord>
    private var liveUnlockCodes: [UnlockCacheKey: AllowOnceUnlockCode] = [:]

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.store = FileLockedJSONLStore(
            fileURL: RVPolicyPaths.allowOnceFile(inConfigDir: baseDirectory),
            lockURL: RVPolicyPaths.allowOnceLockFile(inConfigDir: baseDirectory),
            directoryURL: baseDirectory
        )
    }

    nonisolated public static func makeLive(home: HomeDirectory) -> AllowOnceStore {
        AllowOnceStore(baseDirectory: RVPolicyPaths.configDirectory(home: home))
    }

    /// Production config dir: `$HOME/.config/rv` only. Does not read `XDG_CONFIG_HOME`.
    nonisolated public static func processHomeConfigDirectory() -> URL? {
        guard let home = HomeDirectory.process() else {
            return nil
        }
        return URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }

    public func mint(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        tty: TTYCapability,
        now: Date,
        robot: Bool = false,
        ttl: TimeInterval = 24 * 60 * 60
    ) async throws -> AllowOnceUnlockCode {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let trimmed = matchingView.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw AllowOnceError.emptyCommand }
        let view = MatchingView(trimmed)
        let fingerprint = commandFingerprint(view)
        let cacheKey = UnlockCacheKey(fingerprint: fingerprint, cwd: cwd.rawValue)
        var lastError: AllowOnceError = .collision
        for _ in 0..<8 {
            let code = try generateAllowOnceCode()
            let hash = sha256Hex(code.rawValue)
            do {
                return try withFileLock {
                    switch try AllowOnceLedger.mint(
                        records: loadRecords(),
                        codeHash: hash,
                        fingerprint: fingerprint,
                        redacted: redactCommand(view),
                        cwd: cwd,
                        ruleID: ruleID,
                        now: now,
                        ttl: ttl
                    ) {
                    case let .reused(records):
                        try writeRecords(records)
                        if let cached = liveUnlockCodes[cacheKey] {
                            return cached
                        }
                        throw AllowOnceError.alreadyPending
                    case let .appended(records):
                        try writeRecords(records)
                        liveUnlockCodes[cacheKey] = code
                        return code
                    }
                }
            } catch let error as AllowOnceError where error == .collision {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Hook deny mint. Not TTY-gated. Returns a six-hex code, `earlierPending`, or nil.
    /// Writes `kind: .pending` only. Never plants a granted row. A live pending
    /// for the same command+cwd is reused instead of minting a new code.
    /// TTL matches the pending-row TTL: the wire-delivered code is visible
    /// to the gated agent, so its bearer window stays short.
    package func mintFromDeny(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval = 15 * 60
    ) async -> AllowOnceUnlockMint? {
        let trimmed = matchingView.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let view = MatchingView(trimmed)
        let fingerprint = commandFingerprint(view)
        let cacheKey = UnlockCacheKey(fingerprint: fingerprint, cwd: cwd.rawValue)
        for _ in 0..<8 {
            let code: AllowOnceUnlockCode
            do {
                code = try generateAllowOnceCode()
            } catch {
                return nil
            }
            let hash = sha256Hex(code.rawValue)
            do {
                return try withFileLock(nonBlocking: true) {
                    switch try AllowOnceLedger.mint(
                        records: loadRecords(),
                        codeHash: hash,
                        fingerprint: fingerprint,
                        redacted: redactCommand(view),
                        cwd: cwd,
                        ruleID: ruleID,
                        now: now,
                        ttl: ttl
                    ) {
                    case let .reused(records):
                        try writeRecords(records)
                        if let cached = liveUnlockCodes[cacheKey] {
                            return .code(cached)
                        }
                        return .earlierPending
                    case let .appended(records):
                        try writeRecords(records)
                        liveUnlockCodes[cacheKey] = code
                        return .code(code)
                    }
                }
            } catch let error as AllowOnceError where error == .collision {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Validates the typed code and flips the pending row as a projection +
    /// fast-path single-use hint. Step 8B.1: the flip creates NO authority;
    /// the CLI must attest to the daemon afterwards. `expectedFingerprint`
    /// binds the flip to the pre-LA display (TOCTOU); mismatch aborts.
    public func redeem(
        code: String,
        tty: TTYCapability,
        now: Date,
        robot: Bool = false,
        expectedFingerprint: String? = nil
    ) async throws -> AllowOnceListRow {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 6, normalized.allSatisfy(\.isHexDigit) else {
            throw AllowOnceError.unknownCode
        }
        let hash = sha256Hex(normalized)
        return try withFileLock {
            switch try AllowOnceLedger.redeem(
                records: loadRecords(),
                codeHash: hash,
                now: now,
                expectedFingerprint: expectedFingerprint
            ) {
            case let .expired(records):
                try writeRecords(records)
                throw AllowOnceError.expired
            case let .granted(records, row):
                try writeRecords(records)
                return row
            }
        }
    }

    /// Single locked read of a live pending row: display row + action
    /// fingerprint, atomically. The redeem ceremony captures both BEFORE
    /// LocalAuthentication and re-checks the fingerprint under the redeem
    /// lock, so a swapped file between display and attest aborts instead
    /// of attesting a row the human never reviewed.
    public func validatePending(
        code: String,
        now: Date
    ) async -> (row: AllowOnceListRow, fingerprint: String)? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AllowOnceUnlockCode(validating: normalized) != nil else { return nil }
        let hash = sha256Hex(normalized)
        return (try? withFileLock {
            AllowOnceLedger.pendingRow(in: loadRecords(), codeHash: hash, now: now)
        }).flatMap { record in
            AllowOnceLedger.rows(records: [record], now: now).first.map {
                (row: $0, fingerprint: record.commandFingerprint)
            }
        }
    }

    /// Daemon projection write: records a memory-table plant/consume as a
    /// display row so `rv allow-once list` stays truthful. Best-effort,
    /// display-only: nothing reads these rows for authority.
    package func project(
        lifecycle: AllowOnceLifecycle,
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        codeHash: String,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async {
        let record = AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: lifecycle,
            codeHash: codeHash,
            commandFingerprint: commandFingerprint(matchingView),
            commandRedacted: redactCommand(matchingView),
            cwd: cwd,
            ruleID: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        try? withFileLock {
            var records = loadRecords()
            records.append(record)
            try writeRecords(records)
        }
    }

    public func list(now: Date) async -> [AllowOnceListRow] {
        AllowOnceLedger.rows(records: loadRecords(), now: now)
    }

    /// Read-only peek at a live pending row for a typed code. Returns nil
    /// for unknown, spent, or expired codes without mutating the ledger.
    /// The redeem ceremony uses this to name the grant in the LA prompt
    /// before authenticating (B-F6); the grant itself still goes through
    /// `redeem`, which re-validates everything under the lock.
    public func peekPending(code: String, now: Date) async -> AllowOnceListRow? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AllowOnceUnlockCode(validating: normalized) != nil else { return nil }
        let hash = sha256Hex(normalized)
        return (try? withFileLock {
            AllowOnceLedger.pendingRow(in: loadRecords(), codeHash: hash, now: now)
        }).flatMap { AllowOnceLedger.rows(records: [$0], now: now).first }
    }

    public func clear(tty: TTYCapability, now: Date) async throws {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        try withFileLock {
            liveUnlockCodes.removeAll()
            try writeRecords(AllowOnceLedger.keepConsumed(records: loadRecords(), now: now))
        }
    }

    private var fileURL: URL {
        RVPolicyPaths.allowOnceFile(inConfigDir: baseDirectory)
    }

    private struct UnlockCacheKey: Hashable, Sendable {
        var fingerprint: String
        var cwd: String
    }

    private func loadRecords() -> [AllowOnceRecord] {
        store.load().filter { $0.schemaVersion == 1 }
    }

    private func writeRecords(_ records: [AllowOnceRecord]) throws {
        do {
            try store.save(records)
        } catch is FileLockedJSONLStoreError {
            // RVFileStore boundary: every save failure (encode or IO) becomes
            // the domain persistence error, so withFileLock only ever sees
            // lock-acquisition or lock-setup failures (FileLockedJSONLStoreError),
            // never untranslated save failures.
            throw AllowOnceError.encodeFailed
        }
    }

    private func withFileLock<T>(nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
        do {
            return try store.withLock(nonBlocking: nonBlocking, body)
        } catch let error as FileLockedJSONLStoreError {
            // Only FileLockedJSONLStoreError-originated failures are caught here:
            // the body throws domain errors (writeRecords translates save
            // failures). IO from lock setup collapses into encodeFailed —
            // fail-closed, and both map to "store unavailable" for callers.
            switch error {
            case .lockFailed:
                throw AllowOnceError.lockFailed
            case .encodeFailed, .ioFailed:
                throw AllowOnceError.encodeFailed
            }
        }
    }
}

public func generateAllowOnceCode() throws -> AllowOnceUnlockCode {
    // Linux standalone has no SystemRandomNumberGenerator.fill; CSPRNG via the generator.
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<3).map { _ in UInt8.random(in: 0...255, using: &generator) }
    let raw = bytes.map { String(format: "%02x", $0) }.joined()
    guard let code = AllowOnceUnlockCode(validating: raw) else {
        throw AllowOnceError.encodeFailed
    }
    return code
}
