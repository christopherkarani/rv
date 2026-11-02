#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Testing
@testable import RVIsolation

@Suite("Workspace publish symlink policy")
struct WorkspacePublishSymlinkPolicyTests {
    @Test(arguments: [
        ("link", "a.txt"),
        ("sub/link", "../a.txt"),
        ("sub/deeper/link", "../../sub/./x"),
        ("link", "missing/inside"),
    ])
    func inTreeRelativeTargetsStayInside(_ link: String, _ target: String) {
        #expect(workspaceSymlinkTargetStaysInside(link: link, target: target, links: [:]))
    }

    @Test(arguments: [
        ("link", "/etc/passwd"),
        ("link", "/"),
        ("link", ""),
        ("link", ".."),
        ("link", "../outside"),
        ("sub/link", "../../outside"),
        ("link", "sub/../../x"),
        ("link", "missing/../.."),
    ])
    func absoluteOrEscapingTargetsAreRefused(_ link: String, _ target: String) {
        #expect(workspaceSymlinkTargetStaysInside(link: link, target: target, links: [:]) == false)
    }

    /// `y -> p/..` with `p -> .` is lexically inside but physically the
    /// workspace's parent. Intermediate links are resolved.
    @Test func targetsThroughOtherLinksAreResolved() {
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "p/..", links: ["p": "."]) == false)
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "abs/x", links: ["abs": "/etc"]) == false)
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "d/file", links: ["d": "sub/deep"]))
        #expect(workspaceSymlinkTargetStaysInside(link: "loop", target: "loop", links: ["loop": "loop"]) == false)
    }

    /// The saved tree is usually case-insensitive: `P/..` reaches the link
    /// `p`, so `y` would be the workspace's parent. A component that matches
    /// a link only by case is refused.
    @Test func caseOnlyLinkMatchesAreRefused() {
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "P/..", links: ["p": "."]) == false)
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "sub/P/..", links: ["sub/p": ".."]) == false)
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "SUB/p/..", links: ["sub/p": ".."]) == false)
        // An exact match still resolves, and unrelated names are unaffected.
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "p/x", links: ["p": "sub"]))
        #expect(workspaceSymlinkTargetStaysInside(link: "y", target: "Q/x", links: ["p": "sub"]))
    }
}

#if os(macOS)
@Suite("Workspace publish atomicity", .serialized)
struct WorkspacePublishAtomicityTests {
    /// One rejected entry among many: nothing is written to the saved tree.
    @Test func oneRejectedEntryPublishesNothing() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        // Replace one saved inode with the same bytes: that entry rejects.
        let tampered = boundary.savedPath.appendingPath("b.txt")
        #expect(unlink(tampered) == 0)
        try Data("b\n".utf8).write(to: URL(fileURLWithPath: tampered))
        let before = try treeState(boundary.savedPath)

        #expect(boundaryFailed(boundary.publishAndRestore()))
        guard case .rejected(let reasons) = boundary.publishOutcome else {
            Issue.record("expected a rejection, got \(boundary.publishOutcome)")
            return
        }
        #expect(reasons.map(\.relative) == ["b.txt"])
        #expect(try treeState(tree.workspaceURL.path) == before)
    }

    /// A finished failure after many committed steps rolls every step back.
    /// "gone" fails before the rollback directory exists. "keep" is the last
    /// step (its directory mode), so the retire of "gone" and every earlier
    /// step have applied and must be undone, including the rename back out
    /// of the rollback directory and the restored 0o750 mode.
    @Test(arguments: ["gone", "keep"])
    func midCommitFailureRollsBack(_ failingName: String) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        let before = try treeState(boundary.savedPath)

        let result = WorkspacePublishFaults.$commitFault.withValue({ _, relative in
            relative == failingName
        }) {
            boundary.publishAndRestore()
        }
        #expect(boundaryFailed(result))
        #expect(boundary.publishOutcome == .rolledBack(failedAt: failingName))
        #expect(try treeState(tree.workspaceURL.path) == before)
        #expect(before["keep"] == "d:750")
        #expect(before["gone/old.txt"] != nil)
        #expect(rollbackLeftovers(tree).isEmpty)
    }

    @Test(arguments: ["/etc/passwd", "../outside", "nested/../../outside"])
    func escapingSymlinkIsRefusedAndNothingPublishes(_ target: String) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        #expect(symlink(target, tree.workspaceURL.appendingPathComponent("escape").path) == 0)
        let before = try treeState(boundary.savedPath)

        #expect(boundaryFailed(boundary.publishAndRestore()))
        #expect(boundary.publishOutcome == .rejected([
            WorkspacePublishRejection(relative: "escape", reason: .symlinkEscapesWorkspace),
        ]))
        #expect(try treeState(tree.workspaceURL.path) == before)
    }

    /// A symlink-policy rejection publishes nothing but must not destroy the
    /// agent's work: the detached image is kept under a name nothing sweeps.
    @Test func symlinkPolicyRejectionRetainsTheImage() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        let original = try #require(identityImagePath(boundary))
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        #expect(symlink("/usr/bin/python3", tree.workspaceURL.appendingPathComponent("escape").path) == 0)
        let before = try treeState(boundary.savedPath)

        #expect(boundaryFailed(boundary.publishAndRestore()))
        #expect(boundary.publishOutcome.isContentPolicyRejection)
        #expect(try treeState(tree.workspaceURL.path) == before)
        let retained = try #require(boundary.retainedRejectedImagePath)
        #expect(retained != original)
        #expect(FileManager.default.fileExists(atPath: original) == false)
        var status = stat()
        #expect(lstat(retained, &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFREG)
        #expect((status.st_mode & 0o777) == 0o600)
        let name = (retained as NSString).lastPathComponent
        #expect(name.hasPrefix("rv-rejected-"))
        #expect(name.hasSuffix(".sparseimage"))
        // Never mounted: nothing is attached at the workspace path.
        #expect(boundary.isReleased)
    }

    /// Tamper and inode rejections keep today's discard: the image is gone.
    @Test func tamperRejectionStillUnlinksTheImage() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        let original = try #require(identityImagePath(boundary))
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        let tampered = boundary.savedPath.appendingPath("b.txt")
        #expect(unlink(tampered) == 0)
        try Data("b\n".utf8).write(to: URL(fileURLWithPath: tampered))

        #expect(boundaryFailed(boundary.publishAndRestore()))
        #expect(boundary.publishOutcome.isContentPolicyRejection == false)
        #expect(boundary.retainedRejectedImagePath == nil)
        #expect(FileManager.default.fileExists(atPath: original) == false)
    }

    /// An escaping symlink beside a tampered inode is not a pure policy
    /// rejection: the mixed outcome discards.
    @Test func mixedRejectionIsNotAContentPolicyRejection() {
        let policy = WorkspacePublishRejection(relative: "e", reason: .symlinkEscapesWorkspace)
        let tamper = WorkspacePublishRejection(relative: "b", reason: .inodeChanged)
        #expect(WorkspacePublishOutcome.rejected([policy]).isContentPolicyRejection)
        #expect(WorkspacePublishOutcome.rejected([policy, tamper]).isContentPolicyRejection == false)
        #expect(WorkspacePublishOutcome.rejected([]).isContentPolicyRejection == false)
        #expect(WorkspacePublishOutcome.committed(leftovers: []).isContentPolicyRejection == false)
    }

    /// `p -> .` and `y -> P/..`: on the case-insensitive saved tree `y` would
    /// resolve to the workspace's parent. The case-only match is refused.
    @Test func caseOnlyLinkChainIsRefusedAndNothingPublishes() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        let ws = tree.workspaceURL
        #expect(symlink(".", ws.appendingPathComponent("p").path) == 0)
        #expect(symlink("P/..", ws.appendingPathComponent("y").path) == 0)
        let before = try treeState(boundary.savedPath)

        #expect(boundaryFailed(boundary.publishAndRestore()))
        #expect(boundary.publishOutcome == .rejected([
            WorkspacePublishRejection(relative: "y", reason: .symlinkEscapesWorkspace),
        ]))
        #expect(try treeState(tree.workspaceURL.path) == before)
    }

    @Test func inTreeRelativeSymlinksPublish() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        try seed(tree)
        let boundary = try establish(tree)
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetainedImage(boundary) }
        try agentEdits(tree)
        let ws = tree.workspaceURL
        #expect(symlink("a.txt", ws.appendingPathComponent("rel").path) == 0)
        #expect(symlink("../a.txt", ws.appendingPathComponent("newdir/up").path) == 0)

        #expect(succeeded(boundary.publishAndRestore()))
        #expect(boundary.publishOutcome == .committed(leftovers: []))
        let manager = FileManager.default
        #expect(try manager.destinationOfSymbolicLink(atPath: ws.appendingPathComponent("rel").path) == "a.txt")
        #expect(try manager.destinationOfSymbolicLink(atPath: ws.appendingPathComponent("newdir/up").path) == "../a.txt")
        #expect(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8) == "a2\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("new.txt"), encoding: .utf8) == "new\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("newdir/n.txt"), encoding: .utf8) == "n\n")
        #expect(manager.fileExists(atPath: ws.appendingPathComponent("gone").path) == false)
        #expect(try String(contentsOf: ws.appendingPathComponent("b.txt"), encoding: .utf8) == "b\n")
        #expect(rollbackLeftovers(tree).isEmpty)
    }

    /// A pre-existing absolute link the agent left alone still publishes;
    /// retargeting it to another absolute path is refused.
    @Test func unchangedAbsoluteSymlinkPublishesButRetargetIsRefused() throws {
        for retarget in [false, true] {
            let tree = try ContainmentTree()
            defer { tree.tearDown() }
            try seed(tree)
            let link = tree.workspaceURL.appendingPathComponent("tool").path
            #expect(symlink("/usr/bin/true", link) == 0)
            let boundary = try establish(tree)
            defer { _ = boundary.discardAndRestore() }
            defer { removeRetainedImage(boundary) }
        defer { removeRetainedImage(boundary) }
            try agentEdits(tree)
            if retarget {
                #expect(unlink(link) == 0)
                #expect(symlink("/usr/bin/false", link) == 0)
            }
            let before = try treeState(boundary.savedPath)
            let result = boundary.publishAndRestore()
            if retarget {
                #expect(boundaryFailed(result))
                #expect(try treeState(tree.workspaceURL.path) == before)
            } else {
                #expect(succeeded(result))
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/usr/bin/true")
                #expect(try String(contentsOf: tree.workspaceURL.appendingPathComponent("a.txt"), encoding: .utf8) == "a2\n")
            }
        }
    }
}

private func boundaryFailed(_ result: Result<Void, IsolationApplyError>) -> Bool {
    if case .failure(.workspaceInodeBoundaryFailed) = result { return true }
    return false
}

private func succeeded(_ result: Result<Void, IsolationApplyError>) -> Bool {
    if case .success = result { return true }
    return false
}

private func seed(_ tree: ContainmentTree) throws {
    let ws = tree.workspaceURL
    try Data("a\n".utf8).write(to: ws.appendingPathComponent("a.txt"))
    try Data("b\n".utf8).write(to: ws.appendingPathComponent("b.txt"))
    try Data("c\n".utf8).write(to: ws.appendingPathComponent("c.txt"))
    try FileManager.default.createDirectory(at: ws.appendingPathComponent("gone"), withIntermediateDirectories: true)
    try Data("old\n".utf8).write(to: ws.appendingPathComponent("gone/old.txt"))
    try FileManager.default.createDirectory(at: ws.appendingPathComponent("keep"), withIntermediateDirectories: true)
    try Data("k\n".utf8).write(to: ws.appendingPathComponent("keep/k.txt"))
    // Directory modes round-trip; read-only files are left out because
    // establish on base cannot copy them yet (closeKeepsReadOnlyFilesReadable).
    #expect(chmod(ws.appendingPathComponent("keep").path, 0o750) == 0)
}

/// Edits through the mounted volume, as the contained agent would.
private func agentEdits(_ tree: ContainmentTree) throws {
    let ws = tree.workspaceURL
    try Data("a2\n".utf8).write(to: ws.appendingPathComponent("a.txt"))
    try Data("c2\n".utf8).write(to: ws.appendingPathComponent("c.txt"))
    #expect(chmod(ws.appendingPathComponent("c.txt").path, 0o600) == 0)
    #expect(chmod(ws.appendingPathComponent("keep").path, 0o755) == 0)
    try Data("new\n".utf8).write(to: ws.appendingPathComponent("new.txt"))
    try FileManager.default.createDirectory(at: ws.appendingPathComponent("newdir"), withIntermediateDirectories: true)
    try Data("n\n".utf8).write(to: ws.appendingPathComponent("newdir/n.txt"))
    try Data("k2\n".utf8).write(to: ws.appendingPathComponent("keep/k.txt"))
    try FileManager.default.removeItem(at: ws.appendingPathComponent("gone"))
}

private func establish(_ tree: ContainmentTree) throws -> WorkspaceInodeBoundary {
    try establishWorkspaceInodeBoundary(at: tree.workspaceURL.path).get()
}

/// A policy rejection keeps the 30 MB image; tests must not leak it.
private func removeRetainedImage(_ boundary: WorkspaceInodeBoundary) {
    if let retained = boundary.retainedRejectedImagePath { unlink(retained) }
}

private func identityImagePath(_ boundary: WorkspaceInodeBoundary) -> String? {
    boundary.recoveryIdentity(
        lockPath: "", lockDevice: 0, lockInode: 0, ownerToken: UUID(),
        snapshotPath: "", snapshotDevice: 0, snapshotInode: 0
    ).imagePath
}

private func rollbackLeftovers(_ tree: ContainmentTree) -> [String] {
    let parent = tree.workspaceURL.deletingLastPathComponent().path
    let names = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
    return names.filter { $0.hasPrefix(".rv-rollback-") }
}

/// Kind, mode, inode-independent content of every name under `root`.
private func treeState(_ root: String) throws -> [String: String] {
    var state: [String: String] = [:]
    func walk(_ relative: String) throws {
        let path = relative.isEmpty ? root : root.appendingPath(relative)
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            let child = relative.isEmpty ? name : relative + "/" + name
            let full = root.appendingPath(child)
            var status = stat()
            #expect(lstat(full, &status) == 0)
            let mode = String(status.st_mode & 0o777, radix: 8)
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                state[child] = "d:\(mode)"
                try walk(child)
            case S_IFLNK:
                state[child] = "l:" + (try FileManager.default.destinationOfSymbolicLink(atPath: full))
            default:
                let bytes = FileManager.default.contents(atPath: full) ?? Data()
                state[child] = "f:\(mode):" + bytes.base64EncodedString()
            }
        }
    }
    try walk("")
    return state
}

private extension String {
    func appendingPath(_ component: String) -> String {
        (self as NSString).appendingPathComponent(component)
    }
}
#endif
