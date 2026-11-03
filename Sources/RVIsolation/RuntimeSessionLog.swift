#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import RVPolicy

/// One persisted start record. The launch path writes this before spawn.
struct RuntimeSessionRecord: Equatable, Sendable {
    let id: UUID
    let host: String?
    let workspace: String
    let backend: String
    let startedAt: Date
    /// Parent workspace. Absent on records written before workspace ownership.
    let workspaceSession: UUID?
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
        var workspaceSession: UUID?
    }

    /// `$HOME/.config/rv/runtime-sessions.jsonl`. Ignores `XDG_CONFIG_HOME`.
    static func productionURL() -> URL? {
        HomeDirectory.processConfigDirectory()?
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
            startedAt: session.startedAt.timeIntervalSince1970,
            workspaceSession: session.workspaceSessionID.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else {
            return .failure(.sessionRecordFailed)
        }
        data.append(UInt8(ascii: "\n"))
        return appendExclusiveLine(data, to: url)
    }

    /// One fsynced JSON line through the shared hardened append primitive.
    static func appendExclusiveLine(
        _ data: Data,
        to url: URL
    ) -> Result<Void, IsolationApplyError> {
        do {
            try JSONLAppendLog.append(data, to: url)
            return .success(())
        } catch {
            return .failure(.sessionRecordFailed)
        }
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
                    startedAt: Date(timeIntervalSince1970: record.startedAt),
                    workspaceSession: record.workspaceSession
                )
            )
        }
        return decoded
    }
}
