import Foundation
import Testing
@testable import RVMCP

/// Pure tests: no filesystem. Snapshots are built in memory; writers and manifest savers are fakes.
@Suite("MCPHostSetupPlan")
struct MCPHostSetupPlanTests {
    private let home = URL(fileURLWithPath: "/home/u")
    private let configuration = MCPConfiguration(servers: [
        MCPServerDefinition(name: "wax", command: "wax-mcp"),
        MCPServerDefinition(name: "oc", command: "bun"),
    ])

    private func json(_ name: String, command: String = "x") -> String {
        #"{"mcpServers": {"\#(name)": {"command": "\#(command)"}}}"#
    }

    private func snapshot(
        _ file: MCPHostFile, _ text: String?, link: Bool = false
    ) -> MCPHostSnapshot {
        MCPHostSnapshot(
            file: file,
            state: MCPFileState(contents: text.map { .data(Data($0.utf8)) } ?? .missing, isSymbolicLink: link))
    }

    private func file(_ host: MCPHost, _ index: Int = 0) -> MCPHostFile {
        MCPHostFile.all(home: home, project: nil, environment: [:]).filter { $0.host == host }[index]
    }

    private func plan(_ snapshots: [MCPHostSnapshot], manifest: [MCPSetupRecord] = []) -> Result<MCPSetupPlan, MCPSetupError> {
        MCPHostSetup.plan(
            snapshots: snapshots, manifest: manifest, configuration: configuration, servers: nil, rvPath: "/opt/rv")
    }

    @Test func planFoldsBothClaudeKeyPathsIntoOneWrite() throws {
        let project = URL(fileURLWithPath: "/work/proj")
        let files = MCPHostFile.all(home: home, project: project, environment: [:])
            .filter { $0.host == .claudeCode && $0.path.lastPathComponent == ".claude.json" }
        #expect(files.count == 2)
        let text = """
            {"mcpServers": {"wax": {"command": "wax-mcp"}}, "projects": {"/work/proj": {"mcpServers": {"oc": {"command": "bun"}}}}}
            """
        let plan = try plan(files.map { snapshot($0, text) }).get()
        #expect(plan.writes.count == 1)
        #expect(plan.writes[0].records.map(\.name) == ["wax", "oc"])
        let written = try JSONValue.parse(plan.writes[0].data, maximumDepth: 64)
        #expect(written["mcpServers"]?["wax"]?["command"] == .string("/opt/rv"))
        #expect(written["projects"]?["/work/proj"]?["mcpServers"]?["oc"]?["command"] == .string("/opt/rv"))
        #expect(plan.report.changed.count == 2)
    }

    @Test func planRefusesALaterSymlinkBeforeAnyWrite() throws {
        let cursor = file(.cursor)
        let claude = file(.claudeCode)
        let outcome = plan([
            snapshot(claude, json("wax", command: "wax-mcp")),
            snapshot(cursor, json("oc", command: "bun"), link: true),
        ])
        #expect(outcome == .failure(.symbolicLink(cursor.path.path)))
    }

    @Test func planRefusesLaterCommentsAndUnreadableFiles() {
        let claude = file(.claudeCode)
        let cursor = file(.cursor)
        let commented = "{\"mcpServers\": {\"oc\": {\"command\": \"bun\"}}, // c\n}"
        #expect(plan([snapshot(claude, json("wax")), snapshot(cursor, commented)]) == .failure(.hasComments(cursor.path.path)))
        #expect(plan([snapshot(claude, json("wax")), snapshot(cursor, "{")]) == .failure(.unreadable(cursor.path.path)))
    }

    @Test func planManifestCoversOnlyWrittenPaths() throws {
        let claude = file(.claudeCode)
        let cursor = file(.cursor)
        let prior = MCPSetupRecord(
            host: "x", configPath: "/p", keyPath: ["mcpServers"], name: "n", original: .null, written: .null)
        let plan = try plan([snapshot(claude, json("wax")), snapshot(cursor, json("oc"))], manifest: [prior]).get()
        #expect(plan.manifest(written: []) == [prior])
        let first = plan.manifest(written: [claude.path.path])
        #expect(first.map(\.name) == ["n", "wax"])
        #expect(plan.manifest(written: plan.allPaths).map(\.name) == ["n", "wax", "oc"])
    }

    @Test func applyReportsFilesWrittenBeforeAFailure() throws {
        let claude = file(.claudeCode)
        let cursor = file(.cursor)
        let plan = try plan([snapshot(claude, json("wax")), snapshot(cursor, json("oc"))]).get()
        var saved: [[String]] = []
        let outcome = MCPHostSetup.apply(
            plan,
            write: { url, _ in url == claude.path ? ["/b/claude"] : nil },
            saveManifest: { saved.append($0.map(\.name)); return true })
        guard case .failure(.partial(let applied, let cause)) = outcome else {
            Issue.record("expected partial, got \(outcome)")
            return
        }
        #expect(cause == .writeFailed(cursor.path.path))
        #expect(applied.changed.count == 1)
        #expect(applied.backups == ["/b/claude"])
        #expect(saved == [["wax", "oc"], ["wax"]])
    }

    @Test func applyWritesNothingWhenTheIntentSaveFails() throws {
        let plan = try plan([snapshot(file(.claudeCode), json("wax"))]).get()
        var wrote = false
        let outcome = MCPHostSetup.apply(plan, write: { _, _ in wrote = true; return [] }, saveManifest: { _ in false })
        #expect(outcome == .failure(.manifest("could not save")))
        #expect(wrote == false)
    }

    @Test func applyWithNoWritesSavesNothing() throws {
        let plan = try plan([snapshot(file(.claudeCode), json("other"))]).get()
        var saves = 0
        let outcome = try MCPHostSetup.apply(plan, write: { _, _ in [] }, saveManifest: { _ in saves += 1; return true }).get()
        #expect(saves == 0)
        #expect(outcome.skipped.count == 1)
    }

    // MARK: undo

    private func routed(_ host: MCPHost) throws -> (record: MCPSetupRecord, state: MCPFileState, path: String) {
        let target = file(host)
        var object = JSONObject()
        object["command"] = .string("orig")
        let original = JSONValue.object(object)
        let gateway = MCPHostSetup.gatewayEntry(rvPath: "/opt/rv", server: "wax", original: object, opencode: false)
        let record = MCPSetupRecord(
            host: host.rawValue, configPath: target.path.path, keyPath: ["mcpServers"], name: "wax",
            original: original, written: gateway)
        let text = JSONValue.object(["mcpServers": .object(["wax": gateway])]).prettyText
        return (record, MCPFileState(contents: .data(Data(text.utf8)), isSymbolicLink: false), target.path.path)
    }

    @Test func undoApplyKeepsRecordsOfFilesItCouldNotRestore() throws {
        let a = try routed(.claudeCode)
        let b = try routed(.cursor)
        let plan = try MCPHostSetup.planUndo(
            manifest: [a.record, b.record], snapshots: [a.path: a.state, b.path: b.state], host: nil, servers: nil).get()
        #expect(plan.writes.count == 2)
        var saved: [[String]] = []
        let failingPath = b.path
        let outcome = MCPHostSetup.apply(
            plan, write: { url, _ in url.path == failingPath ? nil : ["/b"] },
            saveManifest: { saved.append($0.map(\.host)); return true })
        guard case .failure(.partial(let applied, _)) = outcome else {
            Issue.record("expected partial, got \(outcome)")
            return
        }
        #expect(applied.changed.count == 1)
        #expect(saved == [["cursor"]])
    }

    @Test func undoApplyReportsRestoresWhenTheManifestSaveFails() throws {
        let a = try routed(.claudeCode)
        let plan = try MCPHostSetup.planUndo(manifest: [a.record], snapshots: [a.path: a.state], host: nil, servers: nil).get()
        let outcome = MCPHostSetup.apply(plan, write: { _, _ in ["/b"] }, saveManifest: { _ in false })
        guard case .failure(.partial(let applied, let cause)) = outcome else {
            Issue.record("expected partial, got \(outcome)")
            return
        }
        #expect(cause == .manifest("could not save"))
        #expect(applied.backups == ["/b"])
    }

    @Test func undoPlanRefusesASymlinkBeforeAnyWrite() throws {
        let a = try routed(.claudeCode)
        var b = try routed(.cursor)
        b.state.isSymbolicLink = true
        let outcome = MCPHostSetup.planUndo(
            manifest: [a.record, b.record], snapshots: [a.path: a.state, b.path: b.state], host: nil, servers: nil)
        guard case .failure(.symbolicLink(let path)) = outcome else {
            Issue.record("expected symlink refusal")
            return
        }
        #expect(path == b.path)
    }

    @Test func undoPlanDropsRecordsForMissingFiles() throws {
        let a = try routed(.claudeCode)
        let plan = try MCPHostSetup.planUndo(
            manifest: [a.record], snapshots: [a.path: MCPFileState(contents: .missing, isSymbolicLink: false)],
            host: nil, servers: nil).get()
        #expect(plan.writes.isEmpty)
        #expect(plan.manifest(written: []).isEmpty)
        #expect(plan.report.skipped.count == 1)
    }
}
