#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain

/// One persisted start record. The launch path writes this before spawn.
struct RuntimeSessionRecord: Equatable, Sendable {
    let id: UUID
    let host: String?
    let workspace: String
    let backend: String
    let startedAt: Date
}

/// Append-only start log for contained launches.
///
/// Not the denial ledger and not a hook-approval store. A failed append
/// refuses the launch. Callers inject `RuntimeSessionStore` in tests.
struct RuntimeSessionStore: Sendable {
    var append: @Sendable (RuntimeSession) -> Result<Void, IsolationApplyError>

    static let production = RuntimeSessionStore { session in
        guard let url = RuntimeSessionLog.productionURL() else {
            return .failure(.sessionRecordFailed)
        }
        return RuntimeSessionLog.append(session, to: url)
    }

    static func file(_ url: URL) -> RuntimeSessionStore {
        RuntimeSessionStore { session in
            RuntimeSessionLog.append(session, to: url)
        }
    }

    static func failing(_ error: IsolationApplyError) -> RuntimeSessionStore {
        RuntimeSessionStore { _ in .failure(error) }
    }
}

enum RuntimeSessionLog {
    private struct Encoded: Codable {
        var id: UUID
        var host: String?
        var workspace: String
        var backend: String
        var startedAt: Double
    }

    /// `$HOME/.config/rv/runtime-sessions.jsonl`. Ignores `XDG_CONFIG_HOME`.
    static func productionURL() -> URL? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
            home.hasPrefix("/"), home.contains("\0") == false
        else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
            .appendingPathComponent("runtime-sessions.jsonl", isDirectory: false)
    }

    static func append(
        _ session: RuntimeSession,
        to url: URL
    ) -> Result<Void, IsolationApplyError> {
        let record = Encoded(
            id: session.id.rawValue,
            host: session.host?.rawValue,
            workspace: session.workspace.rawValue,
            backend: session.backend.rawValue,
            startedAt: session.startedAt.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else {
            return .failure(.sessionRecordFailed)
        }
        data.append(UInt8(ascii: "\n"))
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return .failure(.sessionRecordFailed)
        }
        let fd = url.path.withCString { path in
            open(path, O_CREAT | O_APPEND | O_WRONLY | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else {
            return .failure(.sessionRecordFailed)
        }
        defer { close(fd) }
        guard writeAll(fd, data), sync(fd) else {
            return .failure(.sessionRecordFailed)
        }
        return .success(())
    }

    /// Writes `data` in full. A short write is finished or closed with a newline
    /// so the next append cannot be concatenated onto a partial JSON line.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        var interrupts = 0
        while offset < bytes.count {
            var writeError: Int32 = 0
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                let wrote = write(fd, base.advanced(by: offset), bytes.count - offset)
                if wrote < 0 {
                    writeError = errno
                }
                return wrote
            }
            if count > 0 {
                offset += count
                interrupts = 0
                continue
            }
            if count < 0, writeError == EINTR, interrupts < 16 {
                interrupts += 1
                continue
            }
            if offset > 0 {
                var newline = UInt8(ascii: "\n")
                _ = withUnsafePointer(to: &newline) { pointer in
                    write(fd, pointer, 1)
                }
            }
            return false
        }
        return true
    }

    private static func sync(_ fd: Int32) -> Bool {
        for _ in 0..<16 {
            if fsync(fd) == 0 {
                return true
            }
            if errno != EINTR {
                return false
            }
        }
        return false
    }

    static func records(at url: URL) -> [RuntimeSessionRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        var decoded: [RuntimeSessionRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                let record = try? decoder.decode(Encoded.self, from: data)
            else {
                continue
            }
            decoded.append(
                RuntimeSessionRecord(
                    id: record.id,
                    host: record.host,
                    workspace: record.workspace,
                    backend: record.backend,
                    startedAt: Date(timeIntervalSince1970: record.startedAt)
                )
            )
        }
        return decoded
    }
}
