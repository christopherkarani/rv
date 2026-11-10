import ArgumentParser
import Foundation
import RVDomain
import RVIsolation
import RVPolicy

/// `rv workspace vms`: VM-backed runtime sessions from
/// `runtime-sessions.jsonl`, newest first. Read-only. macOS-guest
/// (`--macvm`) launches record as `microvm` too; only the process
/// sandboxes (seatbelt, landlock) are left out.
enum WorkspaceVMsRun {
    static let defaultLimit = 100
    static let maxLimit = 1000
    private static let sandboxBackends: Set<String> = [
        RuntimeIsolationBackend.seatbelt.rawValue, RuntimeIsolationBackend.landlock.rawValue,
    ]

    struct Row: Encodable, Equatable {
        let backend: String
        let host: String?
        let id: String
        let startedAt: Date
        let workspace: String
        let workspaceSession: String?

        enum CodingKeys: String, CodingKey {
            case backend, host, id
            case startedAt = "started_at"
            case workspace
            case workspaceSession = "workspace_session"
        }
    }

    struct Document: Encodable, Equatable {
        let schema = "rv.vms.v1"
        let vms: [Row]
    }

    static func rows(home: HomeDirectory, limit: Int) -> [Row] {
        let url = RVPolicyPaths.configDirectory(home: home)
            .appendingPathComponent("runtime-sessions.jsonl", isDirectory: false)
        let vms = RuntimeSessionLog.records(at: url)
            .filter { sandboxBackends.contains($0.backend) == false }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
        return vms.map {
            Row(
                backend: $0.backend, host: $0.host, id: $0.id.uuidString, startedAt: $0.startedAt,
                workspace: $0.workspace, workspaceSession: $0.workspaceSession?.uuidString
            )
        }
    }

    static func list(home: HomeDirectory, json: Bool, limit: Int = defaultLimit) throws -> String {
        let rows = rows(home: home, limit: limit)
        if json {
            return try RobotJSON.encode(Document(vms: rows), options: .compactISO8601) + "\n"
        }
        if rows.isEmpty {
            return "no micro VM sessions\n"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return rows.map { row in
            [
                formatter.string(from: row.startedAt), row.backend, row.host ?? "-",
                DisplayedText.field(row.workspace), row.id,
            ].joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
}

struct WorkspaceVMsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vms",
        abstract: "List micro-VM runtime sessions, newest first."
    )

    @Option(name: .long, help: "Most rows to show (1-1000, default 100).")
    var limit: Int = WorkspaceVMsRun.defaultLimit

    @OptionGroup
    var format: FormatFlags

    func validate() throws {
        guard (1...WorkspaceVMsRun.maxLimit).contains(limit) else {
            throw ValidationError("--limit must be 1-\(WorkspaceVMsRun.maxLimit)")
        }
    }

    func run() throws {
        let ctx = CommandContext.current(command: "workspace vms", format: format)
        let home = try ctx.requireHome()
        ctx.writeStdout(try WorkspaceVMsRun.list(home: home, json: ctx.explicitRobot, limit: limit))
    }
}
