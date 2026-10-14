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

    @Test func plantedMissingScratchComponentIsNotTheLeaf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-planted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let caches = root.appendingPathComponent("home/Library/Caches")
        let mcp = caches.appendingPathComponent("rv-mcp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("MARKER".utf8).write(to: project.appendingPathComponent("MARKER"))
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)

        let leaf = mcp.appendingPathComponent("server")
        let leafPin = try #require(MCPSandbox.pinExistingAncestors(leaf.path))
        #expect(leafPin.missing == ["server"])
        try FileManager.default.moveItem(at: project, to: leaf)
        #expect(MCPSandbox.createPinned(leaf.path, pinned: leafPin) == false)
        #expect(FileManager.default.fileExists(atPath: leaf.appendingPathComponent("MARKER").path))
        #expect(FileManager.default.fileExists(atPath: leaf.appendingPathComponent("server").path) == false)

        try FileManager.default.moveItem(at: leaf, to: project)
        try FileManager.default.removeItem(at: mcp)
        let nested = caches.appendingPathComponent("rv-mcp/server")
        let nestedPin = try #require(MCPSandbox.pinExistingAncestors(nested.path))
        #expect(nestedPin.missing == ["rv-mcp", "server"])
        try FileManager.default.moveItem(at: project, to: caches.appendingPathComponent("rv-mcp"))
        #expect(MCPSandbox.createPinned(nested.path, pinned: nestedPin) == false)
        let planted = caches.appendingPathComponent("rv-mcp")
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("MARKER").path))
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("server").path) == false)
    }

    @Test func missingDotDotDoesNotHangAndStillNamesTheTarget() {
        let resolved = MCPSandbox.resolvingMissingSuffix("/private/tmp/no-such/../future-keys")
        #expect(resolved.contains("..") == false)
        #expect(resolved.hasSuffix("/future-keys"))
        #expect(resolved == "/private/tmp/future-keys")
    }

    @Test func scratchPinFailureEscapesThePath() {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let path = "/tmp/\u{202E}link/Library/Caches/rv-mcp/notes\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence
        let message = MCPSandbox.scratchCreationFailure(path)
        #expect(message.hasPrefix("could not create "))
        #expect(message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(message.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(message.contains("\\u001b[2J"))
        #expect(message.contains("\\u2028"))
        #expect(message.contains("\\u202e"))
        #expect(message.contains("\\\\u001b") == false)
        let lines = message.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
    }

    @Test func swappedCachesAfterTheAncestorMatchDoesNotCreateTheLeaf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-caches-swap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("MARKER".utf8).write(to: project.appendingPathComponent("MARKER"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
            try? FileManager.default.moveItem(at: caches, to: aside)
            try? FileManager.default.moveItem(at: project, to: caches)
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: aside.appendingPathComponent("rv-mcp/server").path) == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("MARKER").path))
        #expect(FileManager.default.fileExists(atPath: project.path) == false)
    }

    @Test func dotDotThroughASymlinkNamesThePrivateTmpTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-kernel-dotdot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        let anchor = root.appendingPathComponent("private/tmp/anchor")
        try FileManager.default.createDirectory(at: anchor.appendingPathComponent("foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/../private/tmp/future-keys",
            me.path + "/jump/./../private/tmp/future-keys",
            me.path + "/jump/foo/../../private/tmp/future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.resolvingMissingSuffix(shape) == "/private/tmp/private/tmp/future-keys")
        }
        let tree = me.path + "/jump/foo/../../private/tmp/future-keys"
        #expect(symlink(anchor.path, me.appendingPathComponent("jump-real").path) == 0)
        let followed = me.path + "/jump-real/foo/../../private/tmp/future-keys"
        let kernel = root.path + "/private/tmp/private/tmp/future-keys"
        #expect(MCPSandbox.resolvingMissingSuffix(followed) == kernel)
        #expect(MCPSandbox.resolvingMissingSuffix(tree) == "/private/tmp/private/tmp/future-keys")
    }

    @Test func npmOrCacheSwapAfterTheAncestorMatchDoesNotCreateTheLeaf() throws {
        for name in [".npm", ".cache"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-cache-swap-\(name)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let landed = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("MARKER".utf8).write(to: project.appendingPathComponent("MARKER"))
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
                try? FileManager.default.moveItem(at: project, to: landed)
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("rv-mcp").path) == false)
            #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("rv-mcp").path) == false)
            #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("MARKER").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: root.appendingPathComponent("tmp").path)
            guard case .failure = profile else {
                Issue.record("profile allowed \(name) after the project was moved there")
                return
            }
            #expect(String(describing: profile).contains("(allow file-write*") == false)
            #expect(String(describing: profile).contains("(subpath \"\(landed.path)\")") == false)
        }
    }

    @Test func cachesSwapAfterCreatePinnedDoesNotAllowTheProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-after-pin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("MARKER".utf8).write(to: project.appendingPathComponent("src/App.swift"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        #expect(MCPSandbox.createPinned(scratch.path, pinned: pin))
        try FileManager.default.moveItem(at: caches, to: aside)
        try FileManager.default.moveItem(at: project, to: caches)
        let profile = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: root.appendingPathComponent("tmp").path)
        guard case .failure = profile else {
            Issue.record("profile allowed Caches after it became the project")
            return
        }
        #expect(String(describing: profile).contains("(allow file-write*") == false)
        #expect(String(describing: profile).contains("(subpath \"\(caches.path)\")") == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("src/App.swift").path))
    }

    @Test func librarySymlinkAfterTheAncestorMatchDoesNotCreateTheLeafInTheProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-library-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")
        let aside = home.appendingPathComponent("Library.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("MARKER".utf8).write(to: project.appendingPathComponent("MARKER"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
            try? FileManager.default.moveItem(at: caches, to: project.appendingPathComponent("Caches"))
            try? FileManager.default.moveItem(at: library, to: aside)
            _ = symlink(project.path, library.path)
        }
        #expect(created == false)
        let planted = project.appendingPathComponent("Caches")
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("rv-mcp").path) == false)
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("rv-mcp/server").path) == false)
        #expect(FileManager.default.fileExists(atPath: planted.appendingPathComponent("MARKER").path) == false)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("MARKER").path))
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
        let variable = MCPSandbox.seatbeltPathPattern("/var/mid")
        #expect(wholeMatch(variable, "/private/var/mid/id_rsa"))
        #expect(wholeMatch(variable, "/var/mid/id_rsa"))
        #expect(wholeMatch(temporary, "/System/Volumes/Data/private/tmp/mid/id_rsa"))
        let opt = MCPSandbox.seatbeltPathPattern("/opt/future-keys")
        #expect(wholeMatch(opt, "/opt/future-keys/id_rsa"))
        #expect(wholeMatch(opt, "/System/Volumes/Data/opt/future-keys/id_rsa"))
        #expect(wholeMatch(opt, "/opt/secret/id_rsa") == false)
        let longS = MCPSandbox.seatbeltPathPattern("/private/tmp/future-keys")
        #expect(wholeMatch(longS, "/private/tmp/fu\u{017F}ture-keys/id_rsa"))
        #expect(wholeMatch(longS, "/private/tmp/Future-Keys/id_rsa"))
        let sigma = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{03C3}-keys")
        #expect(wholeMatch(sigma, "/private/tmp/\u{03C2}-keys/id_rsa"))
        #expect(wholeMatch(sigma, "/private/tmp/\u{03A3}-keys/id_rsa"))
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
