import Foundation
import RVDomain
import RVHooks
import Testing

/// The Python stdin adapters decide on their own whether to consult rv, so
/// their pre-filter must not skip rv for a payload rv would refuse or
/// guard: a duplicate key anywhere blocks without consulting rv, and a
/// missing pre-tool event or a near-variant tool name is still sent to rv.
/// rv is "missing" here, so consulting it shows up as the not-installed
/// block and skipping it as an allow.
struct PythonAdapterStrictInputTests {
    private enum Outcome: Equatable {
        case allowed
        case blocked(String)
    }

    private func run(_ host: HookHost, payload: String) async throws -> Outcome {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-pystrict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rvPath = root.appendingPathComponent("missing-rv").path
        let adapter = root.appendingPathComponent("rv-guard.py")
        try HostAdapterResources.load(for: host).rendered(rvPath: rvPath)
            .write(to: adapter, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-S", adapter.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try stdin.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .allowed }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if object["permission"] as? String == "allow" || object["decision"] as? String == "allow" {
            return .allowed
        }
        return .blocked(text)
    }

    private func expectBlocked(_ outcome: Outcome, containing needle: String, _ note: String) {
        guard case .blocked(let text) = outcome else {
            Issue.record("allowed: \(note)")
            return
        }
        #expect(text.contains(needle), "\(note): \(text)")
    }

    private let badRequest = "could not read the hook request"
    private let consulted = "rv is not installed"

    @Test func duplicateKeysBlockWithoutConsultingRv() async throws {
        let cases: [(HookHost, String)] = [
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls","command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_name":"Foo","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Foo","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.codex, #"{"hook_event_name":"PreToolUse","tool_name":"Foo","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.cursor, #"{"hook_event_name":"preToolUse","tool_name":"Task","tool_name":"Shell","tool_input":{"command":"rm -rf /"}}"#),
            (.antigravity, #"{"toolCall":{"name":"x","name":"run_command","args":{"CommandLine":"rm -rf /"}}}"#),
        ]
        for (host, payload) in cases {
            expectBlocked(try await run(host, payload: payload), containing: badRequest, "\(host) \(payload)")
        }
    }

    @Test func missingOrVariantEventStillConsultsRv() async throws {
        let cases: [(HookHost, String)] = [
            (.claude, #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"preToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.codex, #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}"#),
            (.cursor, #"{"hook_event_name":"PreToolUse","tool_name":"Shell","tool_input":{"command":"rm -rf /"}}"#),
            (.cursor, #"{"hook_event_name":" ","command":"rm -rf /"}"#),
        ]
        for (host, payload) in cases {
            expectBlocked(try await run(host, payload: payload), containing: consulted, "\(host) \(payload)")
        }
    }

    @Test func nearVariantToolNamesStillConsultRv() async throws {
        let cases: [(HookHost, String)] = [
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"bash","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Bash ","tool_input":{"command":"rm -rf /"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"read","tool_input":{"file_path":"/x/.env"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":5,"tool_input":{"command":"rm -rf /"}}"#),
            (.codex, #"{"hook_event_name":"PreToolUse","tool_name":"BASH","tool_input":{"command":"rm -rf /"}}"#),
            (.cursor, #"{"hook_event_name":"preToolUse","tool_name":"bash","tool_input":{"command":"rm -rf /"}}"#),
            (.antigravity, #"{"toolCall":{"name":"Run_Command","args":{"CommandLine":"rm -rf /"}}}"#),
        ]
        for (host, payload) in cases {
            expectBlocked(try await run(host, payload: payload), containing: consulted, "\(host) \(payload)")
        }
    }

    /// Other tools and other events keep skipping rv.
    @Test func foreignToolsAndEventsStillAllow() async throws {
        let cases: [(HookHost, String)] = [
            (.claude, #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"BashOutput","tool_input":{}}"#),
            (.claude, #"{"hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{}}"#),
            (.codex, #"{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{}}"#),
            (.cursor, #"{"hook_event_name":"afterShellExecution","command":"ls"}"#),
            (.cursor, #"{"hook_event_name":"preToolUse","tool_name":"Task","tool_input":{}}"#),
            (.antigravity, #"{"toolCall":{"name":"search_web","args":{}}}"#),
        ]
        for (host, payload) in cases {
            #expect(try await run(host, payload: payload) == .allowed, "\(host) \(payload)")
        }
    }
}
