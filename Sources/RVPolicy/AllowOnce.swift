import CryptoKit
import Darwin
import Foundation

public enum AllowOnceConsumeStatus: Sendable, Equatable {
    case consumed(tokenID: String)
    case notFound
    case alreadyConsumed
    case expired
}

public actor AllowOnceStore {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    nonisolated public static func live() -> AllowOnceStore {
        AllowOnceStore(baseDirectory: processHomeRoot() ?? fallbackRoot)
    }

    nonisolated public static func processHomeRoot() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], home.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }

    public func insertGranted(
        matchingView: String,
        cwd: String,
        now: Date,
        ttl: TimeInterval = 24 * 60 * 60
    ) async throws {
        let fingerprint = commandFingerprint(matchingView)
        let record = AllowOnceRecord(
            schemaVersion: 1,
            kind: .granted,
            codeHash: sha256Hex(UUID().uuidString),
            commandFingerprint: fingerprint,
            commandRedacted: "[redacted]",
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

    public func hasGrant(matchingView: String, cwd: String, now: Date) async -> Bool {
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
        matchingView: String,
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
            return .notFound
        }
    }

    private var fileURL: URL {
        baseDirectory.appendingPathComponent("allow-once.jsonl", isDirectory: false)
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
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map { record -> String in
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else {
                throw AllowOnceStoreError.encodeFailed
            }
            return line
        }
        let body = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let temp = fileURL.appendingPathExtension("tmp")
        try body.write(to: temp, atomically: true, encoding: .utf8)
        let renamed: Int32 = fileURL.withUnsafeFileSystemRepresentation { dest in
            temp.withUnsafeFileSystemRepresentation { src in
                guard let dest, let src else { return Int32(-1) }
                return rename(src, dest)
            }
        }
        if renamed != 0 {
            throw AllowOnceStoreError.encodeFailed
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let lockURL = baseDirectory.appendingPathComponent(".allow-once.lock", isDirectory: false)
        if FileManager.default.fileExists(atPath: lockURL.path) == false {
            FileManager.default.createFile(atPath: lockURL.path, contents: Data())
        }
        let fd = lockURL.path.withCString { path in
            open(path, O_RDWR)
        }
        guard fd >= 0 else { throw AllowOnceStoreError.lockFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AllowOnceStoreError.lockFailed }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}

public enum AllowOnceStoreError: Error, Sendable, Equatable {
    case encodeFailed
    case lockFailed
}

struct AllowOnceRecord: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable {
        case pending
        case granted
        case consumed
    }

    var schemaVersion: Int
    var kind: Kind
    var codeHash: String
    var commandFingerprint: String
    var commandRedacted: String
    var cwd: String
    var ruleID: String?
    var createdAt: Date
    var expiresAt: Date
    var consumedAt: Date?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case kind
        case codeHash = "code_hash"
        case commandFingerprint = "command_fingerprint"
        case commandRedacted = "command_redacted"
        case cwd
        case ruleID = "rule_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case consumedAt = "consumed_at"
    }
}

func commandFingerprint(_ matchingView: String) -> String {
    sha256Hex(matchingView)
}

private func sha256Hex(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private let fallbackRoot: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("rv-allow-once-nohome", isDirectory: true)
