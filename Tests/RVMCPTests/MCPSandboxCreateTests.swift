#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVMCP

@Suite("MCP sandbox directory creation")
struct MCPSandboxCreateTests {
    @Test func scratchLeafIsCreatedOnTheCheckedDirectoryAfterTheParentIsSwapped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-swap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.real")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let held = try #require(MCPSandbox.HeldDirectory(path: caches.path))
        try FileManager.default.moveItem(at: caches, to: aside)
        #expect(symlink(project.path, caches.path) == 0)
        #expect(MCPSandbox.createRelative(["rv-mcp", "notes"], holding: held))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("rv-mcp/notes").path))
        #expect(MCPSandbox.createCheckedDirectory(caches.appendingPathComponent("rv-mcp/notes").path) == false)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("rv-mcp").path) == false)
    }

    @Test func scratchLeafIsNotCreatedWhenLibraryItselfIsSwapped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")
        let aside = home.appendingPathComponent("Library.real")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Caches"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let created = caches.appendingPathComponent("rv-mcp/ok")
        #expect(MCPSandbox.createCheckedDirectory(created.path))
        #expect(FileManager.default.fileExists(atPath: created.path))
        try FileManager.default.moveItem(at: library, to: aside)
        #expect(symlink(project.path, library.path) == 0)
        let attacked = library.appendingPathComponent("Caches/rv-mcp/server")
        #expect(MCPSandbox.createCheckedDirectory(attacked.path) == false)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("Caches/rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("Caches/rv-mcp/server").path) == false)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("Caches/rv-mcp/ok").path))
    }
}
