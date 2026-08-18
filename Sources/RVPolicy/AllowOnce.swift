import Darwin
import Foundation

public enum AllowOnceConsumeStatus: Sendable, Equatable {
    case consumed(tokenID: String)
    case notFound
    case alreadyConsumed
    case expired
}

public protocol AllowOnceConsuming: Sendable {
    func consume(command: String, cwd: String) async -> AllowOnceConsumeStatus
    func insert(command: String, cwd: String, expiresAt: Date?) async throws -> String
}

struct AllowOnceGrant: Sendable, Equatable, Codable {
    var command: String
    var cwd: String
    var tokenID: String
    var expiresAt: TimeInterval?
}

public actor MemoryAllowOnceStore: AllowOnceConsuming {
    private var grants: [AllowOnceGrant] = []
    private var consumed: Set<String> = []

    public init() {}

    public func insert(command: String, cwd: String, expiresAt: Date?) async throws -> String {
        let tokenID = UUID().uuidString
        grants.append(
            AllowOnceGrant(
                command: command,
                cwd: cwd,
                tokenID: tokenID,
                expiresAt: expiresAt?.timeIntervalSince1970
            )
        )
        return tokenID
    }

    public func consume(command: String, cwd: String) async -> AllowOnceConsumeStatus {
        guard let index = grants.firstIndex(where: { $0.command == command && $0.cwd == cwd }) else {
            return .notFound
        }
        let grant = grants[index]
        if let expiresAt = grant.expiresAt, Date(timeIntervalSince1970: expiresAt) < Date() {
            return .expired
        }
        if consumed.contains(grant.tokenID) {
            return .alreadyConsumed
        }
        consumed.insert(grant.tokenID)
        return .consumed(tokenID: grant.tokenID)
    }
}

public actor FileAllowOnceStore: AllowOnceConsuming {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func processHomeRoot() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("allow-once", isDirectory: true)
    }

    public func insert(command: String, cwd: String, expiresAt: Date?) async throws -> String {
        try FileManager.default.createDirectory(at: grantsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: consumedDir, withIntermediateDirectories: true)
        let tokenID = UUID().uuidString
        let grant = AllowOnceGrant(
            command: command,
            cwd: cwd,
            tokenID: tokenID,
            expiresAt: expiresAt?.timeIntervalSince1970
        )
        let data = try JSONEncoder().encode(grant)
        let url = grantsDir.appendingPathComponent("\(tokenID).json")
        try data.write(to: url, options: .withoutOverwriting)
        return tokenID
    }

    public func consume(command: String, cwd: String) async -> AllowOnceConsumeStatus {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: grantsDir, includingPropertiesForKeys: nil) else {
            return consumedMatch(command: command, cwd: cwd) ? .alreadyConsumed : .notFound
        }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let grant = try? JSONDecoder().decode(AllowOnceGrant.self, from: data),
                  grant.command == command,
                  grant.cwd == cwd
            else { continue }
            if let expiresAt = grant.expiresAt, Date(timeIntervalSince1970: expiresAt) < Date() {
                return .expired
            }
            let dest = consumedDir.appendingPathComponent(url.lastPathComponent)
            try? fm.createDirectory(at: consumedDir, withIntermediateDirectories: true)
            let ok = url.withUnsafeFileSystemRepresentation { src in
                dest.withUnsafeFileSystemRepresentation { dst in
                    guard let src, let dst else { return false }
                    return rename(src, dst) == 0
                }
            }
            if ok { return .consumed(tokenID: grant.tokenID) }
            return .alreadyConsumed
        }
        return consumedMatch(command: command, cwd: cwd) ? .alreadyConsumed : .notFound
    }

    private var grantsDir: URL { root.appendingPathComponent("grants", isDirectory: true) }
    private var consumedDir: URL { root.appendingPathComponent("consumed", isDirectory: true) }

    private func consumedMatch(command: String, cwd: String) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: consumedDir,
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { url in
            guard let data = try? Data(contentsOf: url),
                  let grant = try? JSONDecoder().decode(AllowOnceGrant.self, from: data)
            else { return false }
            return grant.command == command && grant.cwd == cwd
        }
    }
}
