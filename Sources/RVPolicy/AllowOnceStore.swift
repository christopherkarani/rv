import Darwin
import Foundation
import RVDomain
import Security

public actor AllowOnceStore {
    nonisolated public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    nonisolated public static func live() -> AllowOnceStore {
        AllowOnceStore(baseDirectory: processHomeConfigDirectory() ?? fallbackRoot)
    }

    /// Production config dir: `$HOME/.config/rv` only. Does not read `XDG_CONFIG_HOME`.
    nonisolated public static func processHomeConfigDirectory() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }

    public func mint(
        matchingView: MatchingView,
        cwd: String,
        ruleID: RuleID?,
        tty: TTYCapability,
        now: Date,
        robot: Bool = false,
        ttl: TimeInterval = 24 * 60 * 60
    ) async throws -> String {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        guard robot == false else { throw AllowOnceError.robotRefused }
        let trimmed = matchingView.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw AllowOnceError.emptyCommand }
        let view = MatchingView(trimmed)
        var lastError: AllowOnceError = .collision
        for _ in 0..<8 {
            let code = try generateAllowOnceCode()
            let hash = sha256Hex(code)
            do {
                try withFileLock {
                    var records = loadRecords().filter { $0.expiresAt >= now || $0.kind == .consumed }
                    if records.contains(where: {
                        $0.kind == .pending && $0.codeHash == hash && $0.expiresAt >= now
                    }) {
                        throw AllowOnceError.collision
                    }
                    let record = AllowOnceRecord(
                        schemaVersion: 1,
                        kind: .pending,
                        codeHash: hash,
                        commandFingerprint: commandFingerprint(view),
                        commandRedacted: redactCommand(view),
                        cwd: cwd,
                        ruleID: ruleID?.rawValue,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(ttl),
                        consumedAt: nil
                    )
                    records.append(record)
                    try writeRecords(records)
                }
                return code
            } catch let error as AllowOnceError where error == .collision {
                lastError = error
                continue
            }
        }
        throw lastError
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
            var records = loadRecords()
            guard let index = records.firstIndex(where: {
                $0.kind == .pending && $0.codeHash == hash
            }) else {
                if records.contains(where: {
                    ($0.kind == .granted || $0.kind == .consumed) && $0.codeHash == hash
                }) {
                    throw AllowOnceError.alreadySpent
                }
                throw AllowOnceError.unknownCode
            }
            var pending = records[index]
            guard pending.expiresAt >= now else {
                records.remove(at: index)
                try writeRecords(records)
                throw AllowOnceError.expired
            }
            pending.kind = .granted
            records[index] = pending
            records.removeAll {
                ($0.kind == .pending || $0.kind == .granted) && $0.expiresAt < now
            }
            try writeRecords(records)
            return AllowOnceListRow(
                kind: .granted,
                codeHash: pending.codeHash,
                commandRedacted: pending.commandRedacted,
                cwd: pending.cwd,
                createdAt: pending.createdAt,
                expiresAt: pending.expiresAt
            )
        }
    }

    /// Test / service preload of a grant without minting a code.
    /// Not a human unlock path — does not require a TTY. Keep `package` so CLI cannot plant grants.
    package func insertGranted(
        matchingView: MatchingView,
        cwd: String,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async throws {
        let record = AllowOnceRecord(
            schemaVersion: 1,
            kind: .granted,
            codeHash: sha256Hex(UUID().uuidString),
            commandFingerprint: commandFingerprint(matchingView),
            commandRedacted: redactCommand(matchingView),
            cwd: cwd,
            ruleID: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            consumedAt: nil
        )
        try withFileLock {
            var records = loadRecords()
            records.append(record)
            try writeRecords(records)
        }
    }

    public func hasGrant(matchingView: MatchingView, cwd: String, now: Date) async -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        let fingerprint = commandFingerprint(matchingView)
        let records = loadRecords()
        return records.contains {
            $0.kind == .granted
                && $0.commandFingerprint == fingerprint
                && $0.cwd == cwd
                && $0.expiresAt >= now
        }
    }

    public func consume(
        matchingView: MatchingView,
        cwd: String,
        now: Date
    ) async -> AllowOnceConsumeStatus {
        let fingerprint = commandFingerprint(matchingView)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .notFound
        }
        do {
            return try withFileLock {
                var records = loadRecords()
                let related = records.indices.filter {
                    records[$0].commandFingerprint == fingerprint && records[$0].cwd == cwd
                }
                if let index = related.first(where: {
                    records[$0].kind == .granted && records[$0].expiresAt >= now
                }) {
                    var granted = records[index]
                    granted.kind = .consumed
                    granted.consumedAt = now
                    records[index] = granted
                    records.removeAll {
                        $0.kind == .granted && $0.expiresAt < now
                    }
                    try writeRecords(records)
                    return .consumed(tokenID: granted.codeHash)
                }
                let hadExpiredGrant = related.contains {
                    records[$0].kind == .granted && records[$0].expiresAt < now
                }
                if hadExpiredGrant {
                    records.removeAll {
                        $0.kind == .granted && $0.expiresAt < now
                    }
                    try writeRecords(records)
                    return .expired
                }
                if related.contains(where: { records[$0].kind == .consumed }) {
                    return .alreadyConsumed
                }
                return .notFound
            }
        } catch {
            return .unavailable
        }
    }

    public func list(now: Date) async -> [AllowOnceListRow] {
        loadRecords().compactMap { record in
            guard record.expiresAt >= now || record.kind == .consumed else { return nil }
            guard record.kind != .consumed else {
                return AllowOnceListRow(
                    kind: record.kind,
                    codeHash: record.codeHash,
                    commandRedacted: record.commandRedacted,
                    cwd: record.cwd,
                    createdAt: record.createdAt,
                    expiresAt: record.expiresAt
                )
            }
            return AllowOnceListRow(
                kind: record.kind,
                codeHash: record.codeHash,
                commandRedacted: record.commandRedacted,
                cwd: record.cwd,
                createdAt: record.createdAt,
                expiresAt: record.expiresAt
            )
        }
    }

    public func clear(tty: TTYCapability, now: Date) async throws {
        guard allowsInteractiveAllowOnce(tty) else { throw AllowOnceError.ttyRequired }
        try withFileLock {
            let kept = loadRecords().filter { record in
                record.kind == .consumed && record.expiresAt >= now
            }
            try writeRecords(kept)
        }
    }

    private var fileURL: URL {
        RVPolicyPaths.allowOnceFile(inConfigDir: baseDirectory)
    }

    private func loadRecords() -> [AllowOnceRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard raw.isEmpty == false,
                  let lineData = raw.data(using: .utf8),
                  let record = try? decoder.decode(AllowOnceRecord.self, from: lineData),
                  record.schemaVersion == 1
            else {
                return nil
            }
            return record
        }
    }

    private func writeRecords(_ records: [AllowOnceRecord]) throws {
        try prepareStoreDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map { record -> String in
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else {
                throw AllowOnceError.encodeFailed
            }
            return line
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let temp = fileURL.appendingPathExtension("tmp")
        try body.write(to: temp, atomically: true, encoding: .utf8)
        try setOwnerOnlyFile(temp)
        let renamed: Int32 = fileURL.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        if renamed != 0 {
            throw AllowOnceError.encodeFailed
        }
        try setOwnerOnlyFile(fileURL)
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try prepareStoreDirectory()
        do {
            return try ExclusiveFileLock.withLock(
                at: RVPolicyPaths.allowOnceLockFile(inConfigDir: baseDirectory),
                body
            )
        } catch let error as ExclusiveFileLock.LockError {
            switch error {
            case .lockFailed:
                throw AllowOnceError.lockFailed
            }
        }
    }

    private func prepareStoreDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: baseDirectory.path
        )
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private func generateAllowOnceCode() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 3)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw AllowOnceError.encodeFailed }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private let fallbackRoot: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("rv-allow-once-nohome", isDirectory: true)
