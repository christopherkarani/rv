import Foundation
import Testing
@testable import RVCLI

#if os(macOS)
@Test func workspaceDefaultPrefersTheShellProjectPathAfterHostMountReplacement() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-workspace-path-\(UUID().uuidString)", isDirectory: true)
    let saved = root.appendingPathComponent(".rv-saved-ABCDEF123456", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = try WorkspaceCommandRun.requireProject(
        nil,
        currentDirectory: saved.path,
        environment: ["PWD": project.path]
    )
    #expect(resolved == project.path)
}

@Test func explicitWorkspacePathTakesPrecedenceOverShellPath() throws {
    let resolved = try WorkspaceCommandRun.requireProject(
        "/tmp/explicit-project",
        currentDirectory: "/tmp/.rv-saved-ABCDEF123456",
        environment: ["PWD": "/tmp/logical-project"]
    )
    #expect(resolved == "/tmp/explicit-project")
}

@Test func unusableShellPathFallsBackToTheCurrentDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-workspace-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolved = try WorkspaceCommandRun.requireProject(
        nil,
        currentDirectory: root.path,
        environment: ["PWD": root.appendingPathComponent("missing").path]
    )
    #expect(resolved == root.path)
}
#endif
