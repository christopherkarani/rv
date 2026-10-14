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

    @Test func renamedAncestorDoesNotReceiveTheScratchLeaf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let libraryScratch = caches.appendingPathComponent("rv-mcp/server")
        let libraryPin = try #require(MCPSandbox.pinExistingAncestors(libraryScratch.path))
        let libraryAside = home.appendingPathComponent("Library.real")
        try FileManager.default.moveItem(at: library, to: libraryAside)
        try FileManager.default.moveItem(at: project, to: library)
        #expect(MCPSandbox.createPinned(libraryScratch.path, pinned: libraryPin) == false)
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("Caches/rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: libraryAside.appendingPathComponent("Caches/rv-mcp").path) == false)

        try FileManager.default.moveItem(at: library, to: project)
        try FileManager.default.moveItem(at: libraryAside, to: library)
        let homeScratch = home.appendingPathComponent("Library/Caches/rv-mcp/server")
        let homePin = try #require(MCPSandbox.pinExistingAncestors(homeScratch.path))
        let homeAside = root.appendingPathComponent("home.real")
        try FileManager.default.moveItem(at: home, to: homeAside)
        try FileManager.default.moveItem(at: project, to: home)
        #expect(MCPSandbox.createPinned(homeScratch.path, pinned: homePin) == false)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/rv-mcp").path) == false)

        try FileManager.default.moveItem(at: home, to: project)
        try FileManager.default.moveItem(at: homeAside, to: home)
        let cachesScratch = caches.appendingPathComponent("rv-mcp/server")
        let cachesPin = try #require(MCPSandbox.pinExistingAncestors(cachesScratch.path))
        let cachesAside = library.appendingPathComponent("Caches.real")
        try FileManager.default.moveItem(at: caches, to: cachesAside)
        try FileManager.default.moveItem(at: project, to: caches)
        #expect(MCPSandbox.createPinned(cachesScratch.path, pinned: cachesPin) == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: cachesAside.appendingPathComponent("rv-mcp").path) == false)
    }

    @Test func childStderrIsEscapedWithoutANewline() {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = Data(("\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence).utf8)
        let shown = String(decoding: MCPGatewayRuntime.displayedStderr(raw), as: UTF8.self)
        #expect(shown.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(shown.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(shown.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(shown.contains("\\u001b[2J"))
        #expect(shown.contains("\\u2028"))
        #expect(shown.contains("\\u202e"))
        let lines = shown.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)

        let partial = Data([0xE2, 0x80])
        let split = MCPGatewayRuntime.completeUTF8Prefix(partial)
        #expect(split.complete.isEmpty)
        #expect(split.rest == partial)

        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]) }
        _ = raw.withUnsafeBytes { bytes in
            write(fds[1], bytes.baseAddress, bytes.count)
        }
        close(fds[1])
        var collected = Data()
        MCPGatewayRuntime.relayStderr(fds[0]) { collected.append($0) }
        #expect(String(decoding: collected, as: UTF8.self) == shown)
    }

    @Test func seatbeltPatternMatchesTheCheckedPath() {
        func wholeMatch(_ pattern: String, _ text: String) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { return false }
            return match.range.location == 0 && match.range.length == range.length
        }
        let temporary = MCPSandbox.seatbeltPathPattern("/tmp/mid")
        #expect(wholeMatch(temporary, "/private/tmp/mid/id_rsa"))
        #expect(wholeMatch(temporary, "/tmp/mid/id_rsa"))
        #expect(wholeMatch(temporary, "/tmp/./mid//id_rsa"))
        let users = MCPSandbox.seatbeltPathPattern("/Users/me/decoy")
        #expect(wholeMatch(users, "/System/Volumes/Data/Users/me/decoy/id_rsa"))
        #expect(wholeMatch(users, "/Users/me/decoy/id_rsa"))
        #expect(wholeMatch(users, "/Users/me/./decoy/id_rsa"))
        let sibling = "/Users/me/real-keys/id_rsa"
        #expect(sibling.hasPrefix("/Users/me/"))
        #expect(wholeMatch(users, sibling) == false)
    }

    @Test func undoEscapesTheRecordedHostName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-setup-undo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let name = "\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence
        let record = MCPSetupRecord(
            host: MCPHost.cursor.rawValue, configPath: "/no/such/mcp.json", keyPath: ["mcpServers"],
            name: name, original: .object([:]), written: .object([:]))
        #expect(MCPHostSetup.saveManifest([record], root))
        let undo = MCPHostSetup.undo(host: .cursor, servers: nil, configDirectory: root)
        guard case .success(let result) = undo else {
            Issue.record("undo failed: \(undo)")
            return
        }
        let text = result.skipped.joined(separator: "\n")
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).map(String.init).contains(sentence) == false)
    }
}
