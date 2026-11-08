import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct WorkspaceVMsTests {
    @Test func registeredUnderWorkspace() {
        let names = Workspace.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("vms"))
        #expect(HelpDispatch.topic(arguments: ["workspace", "vms", "--help"]) == .workspace)
    }

    @Test func emptyIsAnEmptyList() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        #expect(try WorkspaceVMsRun.list(home: home, json: true) == #"{"schema":"rv.vms.v1","vms":[]}"# + "\n")
        #expect(try WorkspaceVMsRun.list(home: home, json: false) == "no micro VM sessions\n")
    }

    @Test func keepsVMBackendsNewestFirstAndOmitsAbsentFields() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let directory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = "11111111-1111-1111-1111-111111111111"
        let newer = "22222222-2222-2222-2222-222222222222"
        let parent = "33333333-3333-3333-3333-333333333333"
        let lines = [
            #"{"backend":"microvm","id":"\#(older)","startedAt":1794132000,"workspace":"/w/a"}"#,
            #"{"backend":"seatbelt","host":"claude","id":"44444444-4444-4444-4444-444444444444","startedAt":1794132100,"workspace":"/w/b"}"#,
            "not json",
            #"{"backend":"landlock","id":"55555555-5555-5555-5555-555555555555","startedAt":1794132200,"workspace":"/w/c"}"#,
            #"{"backend":"microvm","host":"claude","id":"\#(newer)","startedAt":1794132300,"workspace":"/w/d","workspaceSession":"\#(parent)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("runtime-sessions.jsonl"), atomically: true, encoding: .utf8)
        let json = try WorkspaceVMsRun.list(home: home, json: true)
        #expect(json == #"{"schema":"rv.vms.v1","vms":[{"backend":"microvm","host":"claude","id":"\#(newer)","started_at":"2026-11-08T10:05:00Z","workspace":"/w/d","workspace_session":"\#(parent)"},{"backend":"microvm","id":"\#(older)","started_at":"2026-11-08T10:00:00Z","workspace":"/w/a"}]}"# + "\n")
        let limited = try WorkspaceVMsRun.list(home: home, json: true, limit: 1)
        #expect(limited.contains(newer))
        #expect(limited.contains(older) == false)
        let pretty = try WorkspaceVMsRun.list(home: home, json: false)
        #expect(pretty.split(separator: "\n").first == "2026-11-08T10:05:00Z  microvm  claude  /w/d  \(newer)")
    }

    @Test func limitOutOfRangeExits64() {
        for argv in [["--limit", "0"], ["--limit", "1001"]] {
            do {
                _ = try WorkspaceVMsCommand.parse(argv)
                Issue.record("\(argv) must not parse")
            } catch {
                #expect(WorkspaceVMsCommand.exitCode(for: error).rawValue == 64)
            }
        }
    }
}
