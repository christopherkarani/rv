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
    /// These tests create and remove `/private/tmp/future-keys` and
    /// `/private/tmp/anchor`. Parallel runs otherwise delete the directory
    /// another test is still reading.
    private static let hostPrivateTmpLock = NSLock()
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
        let opened = "/private/tmp/future-keys"
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape) == [opened])
        }
    }

    @Test func symlinkToAnAncestorOpensThePrivateTmpTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-ancestor-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = root.appendingPathComponent("zone/tmp")
        let anchor = zone.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor.appendingPathComponent("foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("future-keys"), withIntermediateDirectories: true)
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink(anchor.path, me.appendingPathComponent("jump").path) == 0)
        let opened = zone.path + "/future-keys"
        let names = ["x", "alias", "fu\u{00DF}", "\u{FB01}le"]
        for name in names {
            let shape = me.path + "/jump/../\(name)/tmp/future-keys"
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
            let dotted = me.path + "/jump/./../\(name)/tmp/future-keys"
            #expect(MCPSandbox.missingSymlinkOpenings(dotted).contains(opened))
        }
    }

    @Test func laterMissingComponentOpensTheWritableAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-later-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = root.appendingPathComponent("zone/tmp")
        let anchor = zone.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor.appendingPathComponent("foo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("private"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("future-keys"), withIntermediateDirectories: true)
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink(anchor.path, me.appendingPathComponent("jump").path) == 0)
        let opened = zone.path + "/future-keys"
        let shapes = [
            me.path + "/jump/../private/tmp/future-keys",
            me.path + "/jump/./../private/tmp/future-keys",
            me.path + "/jump/foo/../../private/tmp/future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
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

    @Test func nonemptyNpmOrCacheSwapDoesNotCreateTheLeafOrAllowTheProject() throws {
        for name in [".npm", ".cache"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-nonempty-\(name)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let landed = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: landed.appendingPathComponent("_cacache"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
                try? FileManager.default.moveItem(at: project, to: landed.appendingPathComponent("project"))
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("rv-mcp").path) == false)
            #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: temporary.path)
            guard case .failure = profile else {
                Issue.record("profile allowed nonempty \(name) after the project was moved there")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(landed.path)\")") == false)
        }
    }

    @Test func projectMovedUnderCachesDoesNotCreateTheLeafOrAllowCaches() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-caches-child-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        let landed = caches.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
            try? FileManager.default.moveItem(at: project, to: landed)
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: scratch.path) == false)
        #expect(FileManager.default.fileExists(atPath: landed.appendingPathComponent("src/App.swift").path))
        let profile = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: temporary.path)
        guard case .failure = profile else {
            Issue.record("profile allowed Caches after the project was moved under it")
            return
        }
        #expect(String(describing: profile).contains("(subpath \"\(caches.path)\")") == false)
    }

    @Test func plantedScratchLeafDoesNotLetTheCachesSwapAllowTheProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-planted-swap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("rv-mcp/server"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
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
            temporaryDirectory: temporary.path)
        guard case .failure = profile else {
            Issue.record("profile allowed Caches after a planted leaf survived the swap")
            return
        }
        #expect(String(describing: profile).contains("(subpath \"\(caches.path)\")") == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("src/App.swift").path))
    }

    @Test func projectNestedUnderAnExistingCacheChildDoesNotAllowTheCache() throws {
        let nests = [
            (".npm", "_cacache"),
            (".cache", "pip"),
            ("Library/Caches", "com.apple.nsurl"),
        ]
        for (rootName, childName) in nests {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-nested-\(childName)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let watched = home.appendingPathComponent(rootName)
            let child = watched.appendingPathComponent(childName)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: child.appendingPathComponent("kept"))
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
                try? FileManager.default.moveItem(at: project, to: child.appendingPathComponent("project"))
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: scratch.path) == false)
            #expect(FileManager.default.fileExists(atPath: child.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: temporary.path)
            guard case .failure = profile else {
                Issue.record("profile allowed \(watched.path) after the project moved under \(childName)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(watched.path)\")") == false)
        }
    }

    @Test func movingTheLeafInodeIntoTheProjectThenSwappingCachesDoesNotAllowTheProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-leaf-move-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        let planted = project.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        #expect(MCPSandbox.createPinned(scratch.path, pinned: pin))
        try FileManager.default.removeItem(at: planted)
        try FileManager.default.moveItem(at: scratch, to: planted)
        try FileManager.default.moveItem(at: caches, to: aside)
        try FileManager.default.moveItem(at: project, to: caches)
        let profile = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: temporary.path)
        guard case .failure = profile else {
            Issue.record("profile allowed Caches after the recorded leaf moved into the project")
            return
        }
        #expect(String(describing: profile).contains("(subpath \"\(caches.path)\")") == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("src/App.swift").path))
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
        #expect(wholeMatch(longS, "/private/tmp/future-key\u{017F}/id_rsa"))
        #expect(wholeMatch(longS, "/private/tmp/Future-Keys/id_rsa"))
        #expect(wholeMatch(longS, "/private/tmp/future-keys/id_rsa"))
        #expect(wholeMatch(longS, "/private/tmp/fu\u{00DF}ure-keys/id_rsa") == false)
        let kelvin = "/private/tmp/future-\u{212A}eys/id_rsa"
        #expect(wholeMatch(longS, kelvin))
        let sigma = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{03C3}-keys")
        #expect(wholeMatch(sigma, "/private/tmp/\u{03C2}-keys/id_rsa"))
        #expect(wholeMatch(sigma, "/private/tmp/\u{03A3}-keys/id_rsa"))
        let sharp = MCPSandbox.seatbeltPathPattern("/private/tmp/fuss-keys")
        #expect(wholeMatch(sharp, "/private/tmp/fu\u{00DF}-keys/id_rsa"))
        #expect(wholeMatch(sharp, "/private/tmp/fu\u{1E9E}-keys/id_rsa"))
        #expect(wholeMatch(sharp, "/private/tmp/fuSS-keys/id_rsa"))
        let fromSharp = MCPSandbox.seatbeltPathPattern("/private/tmp/fu\u{00DF}-keys")
        #expect(wholeMatch(fromSharp, "/private/tmp/fuss-keys/id_rsa"))
        #expect(wholeMatch(fromSharp, "/private/tmp/fuSS-keys/id_rsa"))
        let ligature = MCPSandbox.seatbeltPathPattern("/private/tmp/file-keys")
        #expect(wholeMatch(ligature, "/private/tmp/\u{FB01}le-keys/id_rsa"))
        let host = MCPSandbox.seatbeltPathPattern("/private/tmp/host-keys")
        #expect(wholeMatch(host, "/private/tmp/ho\u{FB05}-keys/id_rsa"))
        #expect(wholeMatch(host, "/private/tmp/ho\u{FB06}-keys/id_rsa"))
        let office = MCPSandbox.seatbeltPathPattern("/private/tmp/office-keys")
        #expect(wholeMatch(office, "/private/tmp/o\u{FB00}ice-keys/id_rsa"))
        let dotted = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{0130}-keys")
        #expect(wholeMatch(dotted, "/private/tmp/i\u{0307}-keys/id_rsa"))
        let fromDot = MCPSandbox.seatbeltPathPattern("/private/tmp/i\u{0307}-keys")
        #expect(wholeMatch(fromDot, "/private/tmp/\u{0130}-keys/id_rsa"))
        let deseret = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{10428}-keys")
        #expect(wholeMatch(deseret, "/private/tmp/\u{10400}-keys/id_rsa"))
        #expect(wholeMatch(deseret, "/private/tmp/\u{10428}-keys/id_rsa"))
        let fromDeseret = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{10400}-keys")
        #expect(wholeMatch(fromDeseret, "/private/tmp/\u{10428}-keys/id_rsa"))
        let osage = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{104D8}-keys")
        #expect(wholeMatch(osage, "/private/tmp/\u{104B0}-keys/id_rsa"))
        let hungarian = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{10CC0}-keys")
        #expect(wholeMatch(hungarian, "/private/tmp/\u{10C80}-keys/id_rsa"))
        let adlam = MCPSandbox.seatbeltPathPattern("/private/tmp/\u{1E922}-keys")
        #expect(wholeMatch(adlam, "/private/tmp/\u{1E900}-keys/id_rsa"))
        let quoted = MCPSandbox.seatbeltPathPattern("/private/tmp/fu\"ture")
        #expect(quoted.contains("\\\""))
        let ten = String(repeating: "s", count: 10)
        let longRun = MCPSandbox.seatbeltPathPattern("/private/tmp/\(ten)-keys")
        #expect(wholeMatch(longRun, "/private/tmp/\u{00DF}" + String(repeating: "s", count: 8) + "-keys/id_rsa"))
        #expect(wholeMatch(longRun, "/private/tmp/\u{1E9E}" + String(repeating: "s", count: 8) + "-keys/id_rsa"))
        #expect(wholeMatch(longRun, "/private/tmp/s\u{00DF}" + String(repeating: "s", count: 7) + "-keys/id_rsa"))
        #expect(wholeMatch(longRun, "/private/tmp/\(ten)-keys/id_rsa"))
        #expect(wholeMatch(longRun, "/private/tmp/" + String(repeating: "s", count: 9) + "-keys/id_rsa") == false)
        let twelve = String(repeating: "s", count: 12)
        let bare = MCPSandbox.seatbeltPathPattern("/private/tmp/\(twelve)")
        #expect(wholeMatch(bare, "/private/tmp/" + String(repeating: "\u{00DF}", count: 6) + "/id_rsa"))
        #expect(wholeMatch(bare, "/private/tmp/\(twelve)/id_rsa"))
    }

    @Test func dotSymlinkAtTheMissingNameOpensTheCreationDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-dot-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = root.appendingPathComponent("zone/tmp")
        let anchor = zone.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("future-keys"), withIntermediateDirectories: true)
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink(anchor.path, me.appendingPathComponent("jump").path) == 0)
        let opened = zone.path + "/future-keys"
        for name in ["x", "alias", "\u{10428}", "\u{10400}"] {
            let shape = me.path + "/jump/../\(name)/future-keys"
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
            let dotted = me.path + "/jump/./../\(name)/future-keys"
            #expect(MCPSandbox.missingSymlinkOpenings(dotted).contains(opened))
        }
        let foldedName = "\u{10428}-keys"
        try FileManager.default.createDirectory(at: zone.appendingPathComponent(foldedName), withIntermediateDirectories: true)
        let folded = me.path + "/jump/../x/\(foldedName)"
        #expect(MCPSandbox.missingSymlinkOpenings(folded).contains(zone.path + "/" + foldedName))
        let crossed = me.path + "/jump/../x/y/../future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(crossed).contains(opened))
    }

    @Test func laterMissingNameOpensTheWritableAncestor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-fresh-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = root.appendingPathComponent("zone/tmp")
        let anchor = zone.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("future-keys"), withIntermediateDirectories: true)
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink(anchor.path, me.appendingPathComponent("jump").path) == 0)
        let shape = me.path + "/jump/../fresh/link"
        let openings = MCPSandbox.missingSymlinkOpenings(shape)
        #expect(openings.contains(zone.path))
        let deseret = me.path + "/jump/../\u{10428}/link"
        #expect(MCPSandbox.missingSymlinkOpenings(deseret).contains(zone.path))
    }

    @Test func projectUnderAGrandchildOfACacheChildDoesNotAllowTheCache() throws {
        let nests = [
            (".npm", "_cacache/content"),
            (".cache", "pip/http"),
            ("Library/Caches", "com.apple.nsurl/fsCachedData"),
        ]
        for (rootName, childPath) in nests {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-grandchild-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let watched = home.appendingPathComponent(rootName)
            let child = watched.appendingPathComponent(childPath)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("kept".utf8).write(to: child.appendingPathComponent("kept"))
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
                try? FileManager.default.moveItem(at: project, to: child.appendingPathComponent("project"))
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: scratch.path) == false)
            #expect(FileManager.default.fileExists(atPath: child.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: temporary.path)
            guard case .failure = profile else {
                Issue.record("profile allowed \(watched.path) after the project moved under \(childPath)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(watched.path)\")") == false)
        }
    }

    @Test func movingTheLeafWithItsParentThenSwappingCachesDoesNotAllowTheProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-parent-move-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let aside = home.appendingPathComponent("Library/Caches.held")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("rv-mcp/server"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        #expect(MCPSandbox.createPinned(scratch.path, pinned: pin))
        try FileManager.default.removeItem(at: project.appendingPathComponent("rv-mcp"))
        try FileManager.default.moveItem(at: caches.appendingPathComponent("rv-mcp"), to: project.appendingPathComponent("rv-mcp"))
        try FileManager.default.moveItem(at: caches, to: aside)
        try FileManager.default.moveItem(at: project, to: caches)
        let profile = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: temporary.path)
        guard case .failure = profile else {
            Issue.record("profile allowed Caches after rv-mcp moved with the leaf")
            return
        }
        #expect(String(describing: profile).contains("(subpath \"\(caches.path)\")") == false)
        #expect(FileManager.default.fileExists(atPath: caches.appendingPathComponent("src/App.swift").path))
    }

    @Test func deepRelativeLinkAfterTheMissingNameOpensThePrivateTmpTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-deep-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zone = root.appendingPathComponent("zone/tmp")
        let anchor = zone.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zone.appendingPathComponent("future-keys"), withIntermediateDirectories: true)
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink(anchor.path, me.appendingPathComponent("jump").path) == 0)
        let opened = zone.path + "/future-keys"
        let shapes = [
            me.path + "/jump/../link/../../../future-keys",
            me.path + "/jump/../link/../../future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
    }

    @Test func projectMovedIntoAGrandchildAfterTheLeafDoesNotAllowTheCache() throws {
        let nests = [
            (".npm", "_cacache/content"),
            (".cache", "pip/http"),
            ("Library/Caches", "com.apple.nsurl/fsCachedData"),
        ]
        for (rootName, childPath) in nests {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-later-grandchild-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let watched = home.appendingPathComponent(rootName)
            let child = watched.appendingPathComponent(childPath)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            #expect(MCPSandbox.createPinned(scratch.path, pinned: pin))
            try FileManager.default.moveItem(at: project, to: child.appendingPathComponent("project"))
            let widened = MCPSandbox.unreviewedWrite(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, temporaryDirectory: temporary.path)
            #expect(widened?.contains(scratch.path) == true)
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: temporary.path)
            guard case .failure = profile else {
                Issue.record("profile allowed \(watched.path) after the leaf was recorded")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(watched.path)\")") == false)
            #expect(FileManager.default.fileExists(atPath: child.appendingPathComponent("project/src/App.swift").path))
        }
    }

    @Test func symlinkAtAGrandchildPathDoesNotAllowTheCache() throws {
        let nests = [
            (".npm", "_cacache/content", "content"),
            (".cache", "pip/http", "http"),
            ("Library/Caches", "com.apple.nsurl/fsCachedData", "fsCachedData"),
        ]
        for (rootName, childPath, linkName) in nests {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("rv-sandbox-grandchild-link-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let project = root.appendingPathComponent("project")
            let home = root.appendingPathComponent("home")
            let caches = home.appendingPathComponent("Library/Caches")
            let scratch = caches.appendingPathComponent("rv-mcp/server")
            let watched = home.appendingPathComponent(rootName)
            let child = watched.appendingPathComponent(childPath)
            let outside = root.appendingPathComponent("opt/outside/\(linkName)")
            try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
            let temporary = root.appendingPathComponent("tmp")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
            let created = MCPSandbox.createPinned(scratch.path, pinned: pin) {
                _ = symlink(outside.path, child.path)
                try? FileManager.default.moveItem(at: project, to: outside.appendingPathComponent("project"))
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: scratch.path) == false)
            #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
                temporaryDirectory: temporary.path)
            guard case .failure = profile else {
                Issue.record("profile allowed \(watched.path) after a symlink replaced \(childPath)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(watched.path)\")") == false)
        }
    }

    @Test func deepRelativeLinkThroughALaterNameStillOpensThePrivateTmpTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-later-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let opened = "/private/tmp/future-keys"
        let shapes = [
            me.path + "/jump/../link/../../../foo/future-keys",
            me.path + "/jump/../link/../../foo/future-keys",
            me.path + "/jump/../link/../x/future-keys",
            me.path + "/jump/../link/../x/y/future-keys",
            me.path + "/jump/../link/../../../future-keys",
            me.path + "/jump/../link/../../future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
    }

    @Test func privateNameAfterLinkDotDotStillOpensTheCreationDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-private-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let opened = "/private/tmp/future-keys"
        let named = me.path + "/jump/../link/../private/future-keys"
        let nested = me.path + "/jump/../link/../private/foo/future-keys"
        let other = me.path + "/jump/../link/../x/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(named).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(nested).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(other).contains(opened))
    }

    @Test func privateNameAtTheMissingComponentStillOpensTheCreationDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-private-component-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let opened = "/private/tmp/future-keys"
        let named = me.path + "/jump/../private/future-keys"
        let nested = me.path + "/jump/../private/foo/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(named).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(nested).contains(opened))
    }

    @Test func laterNameUnderPrivateTmpStillOpensTheCreationDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-private-tmp-later-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let opened = "/private/tmp/future-keys"
        let named = me.path + "/jump/../private/tmp/x/future-keys"
        let nested = me.path + "/jump/../private/tmp/foo/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(named).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(nested).contains(opened))
    }

    @Test func finalNameUnderARealDirectoryStillOpensTheCredentialDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor { try? FileManager.default.removeItem(atPath: anchor) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-final-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let named = me.path + "/jump/../private/tmp/future-keys/x"
        let nested = me.path + "/jump/../private/tmp/future-keys/foo"
        let anchored = me.path + "/jump/../private/tmp/anchor/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(named).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(nested).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(anchored).contains(opened))
    }

    @Test func singleNameUnderPrivateTmpStillOpensTheKeyDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor { try? FileManager.default.removeItem(atPath: anchor) }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-single-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let named = me.path + "/jump/../private/tmp/x"
        let nested = me.path + "/jump/../private/tmp/foo"
        #expect(MCPSandbox.missingSymlinkOpenings(named).contains(opened))
        #expect(MCPSandbox.missingSymlinkOpenings(nested).contains(opened))
        let exact = [
            me.path + "/jump/../private/tmp/future-keys",
            me.path + "/jump/./../private/tmp/future-keys",
            me.path + "/jump/foo/../../private/tmp/future-keys",
        ]
        for shape in exact {
            #expect(MCPSandbox.missingSymlinkOpenings(shape) == [opened])
        }
        if createdOpened {
            try FileManager.default.removeItem(atPath: opened)
        }
        for shape in exact {
            #expect(MCPSandbox.missingSymlinkOpenings(shape) == [opened])
        }
    }

    @Test func linkDotDotStillOpensTheKeyDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor { try? FileManager.default.removeItem(atPath: anchor) }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-link-dotdot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/../link/../private/tmp/future-keys/x",
            me.path + "/jump/../link/../private/tmp/future-keys/foo",
            me.path + "/jump/../link/../private/tmp/x/future-keys",
            me.path + "/jump/../link/../private/tmp/anchor/future-keys",
            me.path + "/jump/../link/../private/tmp/anchor/x",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
    }

    @Test func anchorChildDotDotStillOpensTheKeyDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let hostFoo = anchor + "/foo"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        let fooExisted = FileManager.default.fileExists(atPath: hostFoo)
        if fooExisted {
            try FileManager.default.removeItem(atPath: hostFoo)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor {
                try? FileManager.default.removeItem(atPath: anchor)
            } else if fooExisted {
                try? FileManager.default.createDirectory(atPath: hostFoo, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(atPath: hostFoo)
            }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-anchor-dotdot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/x/../../private/tmp/future-keys/x",
            me.path + "/jump/x/../../private/tmp/future-keys/foo",
            me.path + "/jump/a/../../private/tmp/future-keys/x",
            me.path + "/jump/foo/../../private/tmp/future-keys/x",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
        let exact = me.path + "/jump/foo/../../private/tmp/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(exact) == [opened])
        try FileManager.default.createDirectory(atPath: hostFoo, withIntermediateDirectories: true)
        let present = me.path + "/jump/foo/../../private/tmp/future-keys/x"
        #expect(MCPSandbox.missingSymlinkOpenings(present).contains(opened))
    }

    @Test func dotLinkBeforeTheKeyDirectoryStillOpensIt() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let hostFoo = anchor + "/foo"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        let fooExisted = FileManager.default.fileExists(atPath: hostFoo)
        if fooExisted {
            try FileManager.default.removeItem(atPath: hostFoo)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor {
                try? FileManager.default.removeItem(atPath: anchor)
            } else if fooExisted {
                try? FileManager.default.createDirectory(atPath: hostFoo, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(atPath: hostFoo)
            }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-dot-before-key-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/x/../../private/tmp/y/future-keys",
            me.path + "/jump/x/../../private/tmp/z/future-keys",
            me.path + "/jump/a/../../private/tmp/y/future-keys",
            me.path + "/jump/foo/../../private/tmp/y/future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
        let exact = me.path + "/jump/foo/../../private/tmp/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(exact) == [opened])
    }

    @Test func siblingLinkStillOpensTheKeyDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let hostFoo = anchor + "/foo"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        let fooExisted = FileManager.default.fileExists(atPath: hostFoo)
        if fooExisted {
            try FileManager.default.removeItem(atPath: hostFoo)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor {
                try? FileManager.default.removeItem(atPath: anchor)
            } else if fooExisted {
                try? FileManager.default.createDirectory(atPath: hostFoo, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(atPath: hostFoo)
            }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-sibling-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/x/../../private/tmp/y",
            me.path + "/jump/x/../../private/tmp/z",
            me.path + "/jump/a/../../private/tmp/y",
            me.path + "/jump/foo/../../private/tmp/y",
            me.path + "/jump/x/../../private/tmp/y/future-keys/x",
            me.path + "/jump/x/../../private/tmp/y/z/future-keys",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
        let exact = me.path + "/jump/foo/../../private/tmp/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(exact) == [opened])
    }

    @Test func missingSuffixStillOpensTheKeyDirectory() throws {
        Self.hostPrivateTmpLock.lock()
        defer { Self.hostPrivateTmpLock.unlock() }
        let opened = "/private/tmp/future-keys"
        let anchor = "/private/tmp/anchor"
        let hostFoo = anchor + "/foo"
        let createdOpened = FileManager.default.fileExists(atPath: opened) == false
        let createdAnchor = FileManager.default.fileExists(atPath: anchor) == false
        if createdOpened {
            try FileManager.default.createDirectory(atPath: opened, withIntermediateDirectories: true)
        }
        if createdAnchor {
            try FileManager.default.createDirectory(atPath: anchor, withIntermediateDirectories: true)
        }
        let fooExisted = FileManager.default.fileExists(atPath: hostFoo)
        if fooExisted {
            try FileManager.default.removeItem(atPath: hostFoo)
        }
        defer {
            if createdOpened { try? FileManager.default.removeItem(atPath: opened) }
            if createdAnchor {
                try? FileManager.default.removeItem(atPath: anchor)
            } else if fooExisted {
                try? FileManager.default.createDirectory(atPath: hostFoo, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(atPath: hostFoo)
            }
        }
        try Data("key".utf8).write(to: URL(fileURLWithPath: opened + "/id_rsa"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-missing-suffix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let me = root.appendingPathComponent("Users/me")
        try FileManager.default.createDirectory(at: me, withIntermediateDirectories: true)
        #expect(symlink("/private/tmp/anchor", me.appendingPathComponent("jump").path) == 0)
        let shapes = [
            me.path + "/jump/x/../../private/tmp/y/w",
            me.path + "/jump/x/../../private/tmp/y/z",
            me.path + "/jump/a/../../private/tmp/y/w",
            me.path + "/jump/foo/../../private/tmp/y/w",
            me.path + "/jump/x/../../private/tmp/y/z/w",
        ]
        for shape in shapes {
            #expect(MCPSandbox.missingSymlinkOpenings(shape).contains(opened))
        }
        let exact = me.path + "/jump/foo/../../private/tmp/future-keys"
        #expect(MCPSandbox.missingSymlinkOpenings(exact) == [opened])
    }

    @Test func preexistingSymlinkThenMoveDoesNotAllowTheCache() throws {
        for planted in plantedCacheLinks {
            let fixture = try plantedCacheLink(planted)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
            #expect(MCPSandbox.createPinned(fixture.scratch, pinned: pin))
            try FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: fixture.scratch, home: fixture.home, configDirectory: fixture.root.appendingPathComponent("config").path,
                temporaryDirectory: fixture.temporary)
            guard case .failure = profile else {
                Issue.record("profile allowed \(fixture.watched) through \(planted.homeLink)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(fixture.watched)\")") == false)
            #expect(FileManager.default.fileExists(atPath: fixture.landing.appendingPathComponent("project/src/App.swift").path))
        }
    }

    @Test func preexistingSymlinkMoveInsideTheHookDoesNotCreateTheLeaf() throws {
        for planted in plantedCacheLinks {
            let fixture = try plantedCacheLink(planted)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
            let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
                try? FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
            #expect(FileManager.default.fileExists(atPath: fixture.landing.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: fixture.scratch, home: fixture.home, configDirectory: fixture.root.appendingPathComponent("config").path,
                temporaryDirectory: fixture.temporary)
            guard case .failure = profile else {
                Issue.record("profile allowed \(fixture.watched) after a move through \(planted.homeLink)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(fixture.watched)\")") == false)
        }
    }

    @Test func sRunFollowedByTStillDeniesTheStLigature() throws {
        func whole(_ component: String, _ file: String) -> Bool {
            seatbeltWholeMatch(
                MCPSandbox.seatbeltPathPattern("/private/tmp/\(component)"),
                "/private/tmp/\(file)")
        }
        #expect(whole("sst-keys", "sst-keys/id_rsa"))
        #expect(whole("sst-keys", "\u{00DF}t-keys/id_rsa"))
        #expect(whole("sst-keys", "s\u{FB05}-keys/id_rsa"))
        #expect(whole("sst-keys", "s\u{FB06}-keys/id_rsa"))
        #expect(whole("sst-keys", "\u{FB05}-keys/id_rsa") == false)
        #expect(whole("ssst-keys", "ss\u{FB05}-keys/id_rsa"))
        #expect(whole("ssst-keys", "ss\u{FB06}-keys/id_rsa"))
        #expect(whole("ssst-keys", "\u{00DF}\u{FB05}-keys/id_rsa"))
        #expect(whole("sssst-keys", "sss\u{FB05}-keys/id_rsa"))
        #expect(whole("ssssst-keys", "ssss\u{FB05}-keys/id_rsa"))
        #expect(whole("bosst", "bos\u{FB05}"))
        #expect(whole("bosst", "bos\u{FB06}"))
        let ten = String(repeating: "s", count: 10)
        #expect(whole("\(ten)-keys", "\u{00DF}" + String(repeating: "s", count: 8) + "-keys/id_rsa"))
        #expect(whole("\(ten)-keys", "\u{1E9E}" + String(repeating: "s", count: 8) + "-keys/id_rsa"))
        #expect(whole("\(ten)-keys", String(repeating: "s", count: 9) + "-keys/id_rsa") == false)
        #expect(whole("host-keys", "ho\u{FB05}-keys/id_rsa"))
        #expect(whole("host-keys", "ho\u{FB06}-keys/id_rsa"))
        #expect(whole("future-keys", "fu\u{00DF}ure-keys/id_rsa") == false)
        #expect(whole("file-keys", "\u{FB01}le-keys/id_rsa"))
        #expect(whole("office-keys", "o\u{FB00}ice-keys/id_rsa"))

        let zone = "/private/tmp/rv-st-ligature-\(UUID().uuidString)"
        let keys = zone + "/sst-keys"
        defer { try? FileManager.default.removeItem(atPath: zone) }
        try FileManager.default.createDirectory(atPath: keys, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-sandbox-st-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let caches = home.appendingPathComponent("Library/Caches")
        let scratch = caches.appendingPathComponent("rv-mcp/server")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".npm"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        let ssh = home.appendingPathComponent(".ssh").path
        #expect(symlink(keys, ssh) == 0)
        let pin = try #require(MCPSandbox.pinExistingAncestors(scratch.path))
        #expect(MCPSandbox.createPinned(scratch.path, pinned: pin))
        #expect(MCPSandbox.missingSymlinkOpenings(ssh).isEmpty)
        let profile = MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: []),
            scratch: scratch.path, home: home.path, configDirectory: root.appendingPathComponent("config").path,
            temporaryDirectory: "/private/tmp")
        guard case .success(let text) = profile else {
            Issue.record("profile failed before the ligature check: \(profile)")
            return
        }
        for scalar in ["\u{FB05}", "\u{FB06}"] {
            let opened = zone + "/s\(scalar)-keys/id_rsa"
            let last = lastFileReadRule(text, path: opened)
            if last?.hasPrefix("(deny ") != true {
                Issue.record("last read rule for \(opened) was \(last ?? "none")")
            }
        }
    }

    @Test func unlistableSymlinkTargetThenMoveDoesNotAllowTheCache() throws {
        for planted in plantedCacheLinks where planted.moveParentUnderRoot == planted.targetUnderRoot {
            let fixture = try plantedCacheLink(planted)
            defer {
                _ = chmod(fixture.landing.path, 0o755)
                try? FileManager.default.removeItem(at: fixture.root)
            }
            #expect(chmod(fixture.landing.path, 0o111) == 0)
            let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
            #expect(MCPSandbox.createPinned(fixture.scratch, pinned: pin))
            #expect(chmod(fixture.landing.path, 0o755) == 0)
            try FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
            #expect(chmod(fixture.landing.path, 0o111) == 0)
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: fixture.scratch, home: fixture.home, configDirectory: fixture.root.appendingPathComponent("config").path,
                temporaryDirectory: fixture.temporary)
            guard case .failure = profile else {
                Issue.record("profile allowed \(fixture.watched) through unlistable \(planted.homeLink)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(fixture.watched)\")") == false)
            #expect(chmod(fixture.landing.path, 0o755) == 0)
            #expect(FileManager.default.fileExists(atPath: fixture.landing.appendingPathComponent("project/src/App.swift").path))
        }
    }

    @Test func unlistableSymlinkMoveInsideTheHookDoesNotCreateTheLeaf() throws {
        for planted in plantedCacheLinks where planted.moveParentUnderRoot == planted.targetUnderRoot {
            let fixture = try plantedCacheLink(planted)
            defer {
                _ = chmod(fixture.landing.path, 0o755)
                try? FileManager.default.removeItem(at: fixture.root)
            }
            #expect(chmod(fixture.landing.path, 0o111) == 0)
            let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
            let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
                _ = chmod(fixture.landing.path, 0o755)
                try? FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
                _ = chmod(fixture.landing.path, 0o111)
            }
            #expect(created == false)
            #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
            #expect(chmod(fixture.landing.path, 0o755) == 0)
            #expect(FileManager.default.fileExists(atPath: fixture.landing.appendingPathComponent("project/src/App.swift").path))
            let profile = MCPSandbox.profile(
                policy: MCPSandboxPolicy(network: false, writable: []),
                scratch: fixture.scratch, home: fixture.home, configDirectory: fixture.root.appendingPathComponent("config").path,
                temporaryDirectory: fixture.temporary)
            guard case .failure = profile else {
                Issue.record("profile allowed \(fixture.watched) after a move into unlistable \(planted.homeLink)")
                return
            }
            #expect(String(describing: profile).contains("(subpath \"\(fixture.watched)\")") == false)
        }
    }

    @Test func unlistableSymlinkChildThenMoveDoesNotAllowTheCache() throws {
        for planted in plantedCacheLinks where planted.moveParentUnderRoot != planted.targetUnderRoot {
            try denyMoveIntoUnlistableChild(planted, duringCreate: false)
        }
    }

    @Test func unlistableSymlinkChildMoveInsideTheHookDoesNotCreateTheLeaf() throws {
        for planted in plantedCacheLinks where planted.moveParentUnderRoot != planted.targetUnderRoot {
            try denyMoveIntoUnlistableChild(planted, duringCreate: true)
        }
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

private struct PlantedCacheLink {
    var homeLink: String
    var targetUnderRoot: String
    var relativeTarget: String?
    var moveParentUnderRoot: String
}

private let plantedCacheLinks = [
    PlantedCacheLink(
        homeLink: ".npm/_cacache/content", targetUnderRoot: "opt/outside/content",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/content"),
    PlantedCacheLink(
        homeLink: ".cache/pip/http", targetUnderRoot: "opt/outside/http",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/http"),
    PlantedCacheLink(
        homeLink: "Library/Caches/com.apple.nsurl/fsCachedData", targetUnderRoot: "opt/outside/fs",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/fs"),
    PlantedCacheLink(
        homeLink: ".npm/_cacache/content", targetUnderRoot: "opt/outside/content",
        relativeTarget: "../../../opt/outside/content", moveParentUnderRoot: "opt/outside/content"),
    PlantedCacheLink(
        homeLink: ".cache/pip/http", targetUnderRoot: "opt/outside/http",
        relativeTarget: "../../../opt/outside/http", moveParentUnderRoot: "opt/outside/http"),
    PlantedCacheLink(
        homeLink: "Library/Caches/com.apple.nsurl/fsCachedData", targetUnderRoot: "opt/outside/fs",
        relativeTarget: "../../../../opt/outside/fs", moveParentUnderRoot: "opt/outside/fs"),
    PlantedCacheLink(
        homeLink: ".npm/_cacache", targetUnderRoot: "opt/outside",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/content"),
    PlantedCacheLink(
        homeLink: ".npm/_cacache", targetUnderRoot: "opt/outside",
        relativeTarget: "../../opt/outside", moveParentUnderRoot: "opt/outside/content"),
    PlantedCacheLink(
        homeLink: ".cache/pip", targetUnderRoot: "opt/outside",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/http"),
    PlantedCacheLink(
        homeLink: ".cache/pip", targetUnderRoot: "opt/outside",
        relativeTarget: "../../opt/outside", moveParentUnderRoot: "opt/outside/http"),
    PlantedCacheLink(
        homeLink: "Library/Caches/com.apple.nsurl", targetUnderRoot: "opt/outside",
        relativeTarget: nil, moveParentUnderRoot: "opt/outside/fsCachedData"),
    PlantedCacheLink(
        homeLink: "Library/Caches/com.apple.nsurl", targetUnderRoot: "opt/outside",
        relativeTarget: "../../../opt/outside", moveParentUnderRoot: "opt/outside/fsCachedData"),
]

private struct PlantedCacheLinkFixture {
    var root: URL
    var home: String
    var scratch: String
    var temporary: String
    var watched: String
    var project: URL
    var landing: URL
}

/// The symlink target stays mode `0111`. The project lands in a directory
/// that already exists under that target, so the target's own link count
/// does not change.
private func denyMoveIntoUnlistableChild(_ planted: PlantedCacheLink, duringCreate: Bool) throws {
    let fixture = try plantedCacheLink(planted)
    let target = fixture.root.appendingPathComponent(planted.targetUnderRoot)
    defer {
        _ = chmod(target.path, 0o755)
        try? FileManager.default.removeItem(at: fixture.root)
    }
    #expect(chmod(target.path, 0o111) == 0)
    let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
    if duringCreate {
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
            try? FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
    } else {
        #expect(MCPSandbox.createPinned(fixture.scratch, pinned: pin))
        try FileManager.default.moveItem(at: fixture.project, to: fixture.landing.appendingPathComponent("project"))
    }
    var info = stat()
    #expect(lstat(target.path, &info) == 0)
    #expect((info.st_mode & 0o777) == 0o111)
    let child = planted.moveParentUnderRoot.dropFirst(planted.targetUnderRoot.count)
    let opened = fixture.home + "/" + planted.homeLink + child + "/project/src/App.swift"
    #expect(String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: opened))) ?? Data(), as: UTF8.self) == "app")
    let resolved = URL(fileURLWithPath: opened).resolvingSymlinksInPath().path
    #expect(resolved.hasSuffix(planted.moveParentUnderRoot + "/project/src/App.swift"))
    let profile = MCPSandbox.profile(
        policy: MCPSandboxPolicy(network: false, writable: []),
        scratch: fixture.scratch, home: fixture.home, configDirectory: fixture.root.appendingPathComponent("config").path,
        temporaryDirectory: fixture.temporary)
    guard case .failure = profile else {
        Issue.record("profile allowed \(fixture.watched) through unlistable \(planted.homeLink)")
        return
    }
    #expect(String(describing: profile).contains("(subpath \"\(fixture.watched)\")") == false)
}

private func plantedCacheLink(_ planted: PlantedCacheLink) throws -> PlantedCacheLinkFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-sandbox-planted-link-\(UUID().uuidString)", isDirectory: true)
    let project = root.appendingPathComponent("project")
    let home = root.appendingPathComponent("home")
    let caches = home.appendingPathComponent("Library/Caches")
    let scratch = caches.appendingPathComponent("rv-mcp/server")
    let link = home.appendingPathComponent(planted.homeLink)
    let target = root.appendingPathComponent(planted.targetUnderRoot)
    let landing = root.appendingPathComponent(planted.moveParentUnderRoot)
    try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data("app".utf8).write(to: project.appendingPathComponent("src/App.swift"))
    try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    let temporary = root.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    if let relativeTarget = planted.relativeTarget {
        guard symlink(relativeTarget, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } else {
        guard symlink(target.path, link.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    let watched: String
    if planted.homeLink.hasPrefix(".npm") {
        watched = home.appendingPathComponent(".npm").path
    } else if planted.homeLink.hasPrefix(".cache") {
        watched = home.appendingPathComponent(".cache").path
    } else {
        watched = caches.path
    }
    return PlantedCacheLinkFixture(
        root: root, home: home.path, scratch: scratch.path, temporary: temporary.path,
        watched: watched, project: project, landing: landing)
}

private func seatbeltWholeMatch(_ pattern: String, _ text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return false }
    return match.range.location == 0 && match.range.length == range.length
}

private func lastFileReadRule(_ profile: String, path: String) -> String? {
    var last: String?
    for line in profile.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        guard text.contains("file-read") else { continue }
        if seatbeltRuleMatches(text, path: path) {
            last = text
        }
    }
    return last
}

private func seatbeltRuleMatches(_ rule: String, path: String) -> Bool {
    let directories = seatbeltQuoted(rule, marker: "(subpath \"", keepEscapes: false)
    let patterns = seatbeltQuoted(rule, marker: "(regex #\"", keepEscapes: true)
    if directories.isEmpty && patterns.isEmpty { return true }
    for directory in directories where path == directory || path.hasPrefix(directory + "/") {
        return true
    }
    return patterns.contains { seatbeltWholeMatch($0, path) }
}

/// Values between `marker` and the closing quote. Subpath text unescapes
/// `\\` and `\"`. A regex keeps those backslashes; only an unescaped quote ends it.
private func seatbeltQuoted(_ rule: String, marker: String, keepEscapes: Bool) -> [String] {
    var found: [String] = []
    var rest = Substring(rule)
    while let range = rest.range(of: marker) {
        var index = range.upperBound
        var value = ""
        var closed = false
        while index < rest.endIndex {
            let character = rest[index]
            if character == "\\" {
                let next = rest.index(after: index)
                guard next < rest.endIndex else { break }
                if keepEscapes { value.append(character) }
                value.append(rest[next])
                index = rest.index(after: next)
                continue
            }
            if character == "\"" {
                found.append(value)
                rest = rest[rest.index(after: index)...]
                closed = true
                break
            }
            value.append(character)
            index = rest.index(after: index)
        }
        if closed == false { break }
    }
    return found
}
