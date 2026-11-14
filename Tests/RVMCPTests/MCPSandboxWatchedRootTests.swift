#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

/// A fixture home under the temp directory as the kernel resolves it
/// (`/private/var/...`): the pinning code refuses a symlinked ancestor,
/// including the `/var` firmlink. Never the real home.
private func fixtureHome(_ label: String) throws -> (root: URL, home: URL, scratch: String, temporary: String) {
    let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
    let root = URL(fileURLWithPath: temporary, isDirectory: true)
        .appendingPathComponent("rv-watched-\(label)-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    for path in ["Library/Caches", ".npm", ".cache", ".ssh"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let tmp = root.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return (root, home, home.appendingPathComponent("Library/Caches/rv-mcp/server").path, tmp.path)
}

private func profile(_ fixture: (root: URL, home: URL, scratch: String, temporary: String)) -> Result<String, MCPLaunchError> {
    MCPSandbox.profile(
        policy: MCPSandboxPolicy(network: false, writable: []), scratch: fixture.scratch, home: fixture.home.path,
        configDirectory: fixture.root.appendingPathComponent("config").path, temporaryDirectory: fixture.temporary)
}

/// The three roots the profile allows by path (`~/Library/Caches`,
/// `~/.npm`, `~/.cache`) must still name the directory they named when the
/// scratch was created and when the profile is written. What happens under
/// them is not checked: the cage may write anywhere under them for the
/// server's whole life, so a change there during creation is no different
/// from the same change a second after launch.
@Suite("MCP sandbox watched roots")
struct MCPSandboxWatchedRootTests {
    static let roots = ["Library/Caches", ".npm", ".cache"]

    /// Browsers, npm and crash reporters write under these roots all the
    /// time; none of that refuses the scratch or the profile.
    @Test(arguments: roots)
    func unrelatedChurnUnderAWatchedRootStillCreatesTheScratch(_ rootName: String) throws {
        let fixture = try fixtureHome("churn")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let watched = fixture.home.appendingPathComponent(rootName)
        let deep = watched.appendingPathComponent("vendor/a/b")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        func churn() {
            try? FileManager.default.createDirectory(
                at: deep.appendingPathComponent("new-\(UUID().uuidString)"), withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: watched.appendingPathComponent("vendor/a/file-\(UUID().uuidString)"))
            try? FileManager.default.createDirectory(
                at: watched.appendingPathComponent("top-\(UUID().uuidString)"), withIntermediateDirectories: true)
            let renamed = watched.appendingPathComponent("vendor/a/b-\(UUID().uuidString)")
            try? FileManager.default.moveItem(at: deep, to: renamed)
            try? FileManager.default.moveItem(at: renamed, to: deep)
        }
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) { churn() }
        #expect(created)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch))
        churn()
        guard case .success = profile(fixture) else {
            Issue.record("profile refused after unrelated churn under \(rootName): \(profile(fixture))")
            return
        }
    }

    /// The root's path now names another directory: refused.
    @Test(arguments: [".npm", ".cache"])
    func watchedRootReplacedByAnotherDirectoryDoesNotCreateTheScratch(_ rootName: String) throws {
        let fixture = try fixtureHome("replaced")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let watched = fixture.home.appendingPathComponent(rootName)
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
            try? FileManager.default.moveItem(at: watched, to: fixture.root.appendingPathComponent("aside"))
            try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: false)
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
    }

    /// The root's path becomes a symlink to a project: refused.
    @Test(arguments: [".npm", ".cache"])
    func watchedRootReplacedByASymlinkDoesNotCreateTheScratch(_ rootName: String) throws {
        let fixture = try fixtureHome("linked")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let watched = fixture.home.appendingPathComponent(rootName)
        let project = fixture.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
            try? FileManager.default.moveItem(at: watched, to: fixture.root.appendingPathComponent("aside"))
            _ = symlink(project.path, watched.path)
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
    }

    /// A root that was there and is gone, or was missing and appears, is
    /// not the root that was read: refused.
    @Test(arguments: [".npm", ".cache"])
    func watchedRootRemovedOrCreatedDoesNotCreateTheScratch(_ rootName: String) throws {
        let fixture = try fixtureHome("appear")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let watched = fixture.home.appendingPathComponent(rootName)
        let removed = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let afterRemoval = MCPSandbox.createPinned(fixture.scratch, pinned: removed) {
            try? FileManager.default.removeItem(at: watched)
        }
        #expect(afterRemoval == false)
        let appeared = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let afterCreation = MCPSandbox.createPinned(fixture.scratch, pinned: appeared) {
            try? FileManager.default.createDirectory(at: watched, withIntermediateDirectories: false)
        }
        #expect(afterCreation == false)
        #expect(FileManager.default.fileExists(atPath: fixture.scratch) == false)
    }

    /// A root swapped after the scratch was created is caught when the
    /// profile is written.
    @Test(arguments: [".npm", ".cache"])
    func watchedRootReplacedBeforeTheProfileIsRefused(_ rootName: String) throws {
        let fixture = try fixtureHome("later")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let watched = fixture.home.appendingPathComponent(rootName)
        let project = fixture.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        #expect(MCPSandbox.createPinned(fixture.scratch, pinned: pin))
        try FileManager.default.moveItem(at: watched, to: fixture.root.appendingPathComponent("aside"))
        try FileManager.default.moveItem(at: project, to: watched)
        guard case .failure = profile(fixture) else {
            Issue.record("profile allowed \(rootName) after it became the project")
            return
        }
    }

    /// `rv-mcp`, between the Caches root and the leaf, swapped for another
    /// directory or a symlink: the held ancestor no longer matches the path.
    @Test(arguments: [false, true])
    func ancestorBetweenTheRootAndTheLeafReplacedDoesNotCreateTheScratch(_ link: Bool) throws {
        let fixture = try fixtureHome("ancestor")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mcp = fixture.home.appendingPathComponent("Library/Caches/rv-mcp")
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        let project = fixture.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        #expect(pin.missing == ["server"])
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
            try? FileManager.default.moveItem(at: mcp, to: fixture.root.appendingPathComponent("aside"))
            if link {
                _ = symlink(project.path, mcp.path)
            } else {
                try? FileManager.default.moveItem(at: project, to: mcp)
            }
        }
        #expect(created == false)
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("server").path) == false)
        #expect(FileManager.default.fileExists(atPath: mcp.appendingPathComponent("server").path) == false)
    }

    /// A project moved into a directory that already exists under a root,
    /// off the scratch's path, during creation. The scratch is created: the
    /// root still names the directory that was reviewed, and the profile's
    /// grant is "anything under this root". Any process that can make this
    /// move can make it a second after launch, when no launch-time check
    /// runs, and the caged server cannot make it itself (the project's
    /// parent is not writable to it).
    @Test(arguments: roots)
    func projectMovedUnderAWatchedRootOffThePathStillCreatesTheScratch(_ rootName: String) throws {
        let fixture = try fixtureHome("moved")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let child = fixture.home.appendingPathComponent(rootName).appendingPathComponent("vendor/content")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let project = fixture.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        let pin = try #require(MCPSandbox.pinExistingAncestors(fixture.scratch))
        let created = MCPSandbox.createPinned(fixture.scratch, pinned: pin) {
            try? FileManager.default.moveItem(at: project, to: child.appendingPathComponent("project"))
        }
        #expect(created)
        #expect(FileManager.default.fileExists(atPath: child.appendingPathComponent("project/src").path))
        guard case .success = profile(fixture) else {
            Issue.record("profile refused: \(profile(fixture))")
            return
        }
    }

    /// Creation reads each root's own entry, never what is under it: a
    /// root holding thousands of directories costs what an empty one does.
    /// Wall time, since no stat-count seam exists; generous for a loaded host.
    @Test func creationUnderALargeCacheDoesNotWalkIt() throws {
        let fixture = try fixtureHome("large")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let caches = fixture.home.appendingPathComponent("Library/Caches")
        for outer in 0..<60 {
            for inner in 0..<50 {
                try FileManager.default.createDirectory(
                    at: caches.appendingPathComponent("app\(outer)/d\(inner)"), withIntermediateDirectories: true)
            }
        }
        let started = Date()
        #expect(MCPSandbox.createCheckedDirectory(fixture.scratch))
        guard case .success = profile(fixture) else {
            Issue.record("profile refused: \(profile(fixture))")
            return
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
#endif
