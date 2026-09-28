import Foundation
import Testing

/// Architectural lock: interactive CLI code attaches to the workspace host
/// through `WorkspaceClient` and never owns a workspace, a runtime, or an
/// admission configuration. Behavior is proven by the frontend suites
/// (`OpenCodeFrontendTests`, `WorkspaceHostTests`); this scan keeps a
/// second ownership path from creeping back into the CLI.
struct WorkspaceOwnershipTests {
    @Test func cliNeverOwnsAWorkspace() throws {
        let cli = cliRoot().appendingPathComponent("Sources/RVCLI", isDirectory: true)
        let forbidden = [
            "WorkspaceSessionSupervisor",
            "launchContainedHost",
            "LocalExecutor",
            "IsolationBackends",
            "superviseSeatbelt",
            "runSingleRuntime",
            "RuntimeAdmissionConfiguration",
            "RuntimeAdmissionSession",
            "normalizeRuntimeAdmission",
            "normalizeRuntimeHTTP",
        ]
        var hits: [String] = []
        guard let enumerator = FileManager.default.enumerator(
            at: cli,
            includingPropertiesForKeys: nil
        ) else {
            Issue.record("cannot enumerate Sources/RVCLI")
            return
        }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let body = try String(contentsOf: url, encoding: .utf8)
            for symbol in forbidden where body.contains(symbol) {
                hits.append("\(url.lastPathComponent): \(symbol)")
            }
        }
        #expect(hits.isEmpty, "CLI owns execution state: \(hits.joined(separator: ", "))")
    }

    @Test func opencodeFrontendUsesTheSharedInteractivePath() throws {
        let command = cliRoot().appendingPathComponent(
            "Sources/RVCLI/Commands/OpenCodeCommand.swift"
        )
        let body = try String(contentsOf: command, encoding: .utf8)
        #expect(body.contains("WorkspaceCommandRun.runInteractive"))
        #expect(body.contains("hook: .opencode"))
        #expect(body.contains("import RVIsolation") == false)
        #expect(body.contains("import RVEngine") == false)
    }
}

private func cliRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
