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
