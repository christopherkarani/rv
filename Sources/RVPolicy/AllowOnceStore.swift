import Foundation
import RVDomain
import RVFileStore

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
    package func mintFromDeny(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        ruleID: RuleID?,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
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

    public func redeem(
        code: String,
        tty: TTYCapability,
        now: Date,
        robot: Bool = false
    ) async throws -> AllowOnceListRow {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 6, normalized.allSatisfy(\.isHexDigit) else {
            throw AllowOnceError.unknownCode
        }
        let hash = sha256Hex(normalized)
        return try withFileLock {
            switch try AllowOnceLedger.redeem(records: loadRecords(), codeHash: hash, now: now) {
            case let .expired(records):
                try writeRecords(records)
                throw AllowOnceError.expired
            case let .granted(records, row):
                try writeRecords(records)
                return row
            }
        }
    }

    /// Test / service preload of a grant without minting a code.
    /// Not a human unlock path — does not require a TTY. Keep `package` so CLI cannot plant grants.
    package func insertGranted(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async throws {
        let record = AllowOnceRecord(
            schemaVersion: 1,
            lifecycle: .granted,
            codeHash: sha256Hex(UUID().uuidString),
            commandFingerprint: commandFingerprint(matchingView),
            commandRedacted: redactCommand(matchingView),
            cwd: cwd,
            ruleID: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        try withFileLock {
            var records = loadRecords()
            records.append(record)
            try writeRecords(records)
        }
    }

    public func hasGrant(matchingView: MatchingView, cwd: WorkingDirectory, now: Date) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        let fingerprint = commandFingerprint(matchingView)
        let records = loadRecords()
        return records.contains { record in
            guard case .granted = record.lifecycle else { return false }
            return record.commandFingerprint == fingerprint
                && record.cwd == cwd
                && record.expiresAt >= now
        }
    }

    /// Host Allow once: plant a granted row and spend it this turn. Not TTY-gated.
    public func plantAndConsume(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async -> AllowOnceConsumeStatus {
        let trimmed = matchingView.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return .notFound
        }
        let view = MatchingView(trimmed)
        do {
            return try withFileLock {
                switch AllowOnceLedger.plantAndConsume(
                    records: loadRecords(),
                    fingerprint: commandFingerprint(view),
                    redacted: redactCommand(view),
                    cwd: cwd,
                    now: now,
                    ttl: ttl,
                    codeHash: sha256Hex(UUID().uuidString)
                ) {
                case let .consumed(tokenID, records):
                    try writeRecords(records)
                    return .consumed(tokenID: tokenID)
                case let .expired(records):
                    try writeRecords(records)
                    return .expired
                case .alreadyConsumed:
                    return .alreadyConsumed
                case .notFound:
                    return .notFound
                }
            }
        } catch {
            return .unavailable
        }
    }

    public func consume(
        matchingView: MatchingView,
        cwd: WorkingDirectory,
        now: Date
    ) async -> AllowOnceConsumeStatus {
        let fingerprint = commandFingerprint(matchingView)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .notFound
        }
        do {
            return try withFileLock {
                switch AllowOnceLedger.consume(
                    records: loadRecords(),
                    fingerprint: fingerprint,
                    cwd: cwd,
                    now: now
                ) {
                case let .consumed(tokenID, records):
                    try writeRecords(records)
                    return .consumed(tokenID: tokenID)
                case let .expired(records):
                    try writeRecords(records)
                    return .expired
                case .alreadyConsumed:
                    return .alreadyConsumed
                case .notFound:
                    return .notFound
                }
            }
        } catch {
            return .unavailable
        }
    }

    public func list(now: Date) async -> [AllowOnceListRow] {
        AllowOnceLedger.rows(records: loadRecords(), now: now)
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
        try store.save(records)
    }

    private func withFileLock<T>(nonBlocking: Bool = false, _ body: () throws -> T) throws -> T {
        do {
            return try store.withLock(nonBlocking: nonBlocking, body)
        } catch let error as FileLockedStoreError {
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
