#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVIsolation

@Suite("Workspace publish case respelling")
struct WorkspacePublishRespellTests {
    private func stamp(_ inode: UInt64, _ kind: WorkspaceInodeStamp.Kind) -> WorkspaceInodeStamp {
        WorkspaceInodeStamp(device: 1, inode: inode, linkCount: 1, kind: kind)
    }

    /// A directory respell moves its whole subtree, and only that subtree.
    @Test func respellingADirectoryMovesItsSubtree() {
        var stamps: [String: WorkspaceInodeStamp] = [
            "Utils": stamp(1, .directory),
            "Utils/a.swift": stamp(2, .regular),
            "Utils/Sub": stamp(3, .directory),
            "Utils/Sub/b.swift": stamp(4, .regular),
            "UtilsX": stamp(5, .regular),
        ]
        var owners = workspaceUniqueInodeOwners(stamps)
        workspaceRespellStamps(from: "Utils", to: "utils", stamps: &stamps, owners: &owners)
        #expect(Set(stamps.keys) == ["utils", "utils/a.swift", "utils/Sub", "utils/Sub/b.swift", "UtilsX"])
        #expect(stamps["utils/Sub/b.swift"]?.inode == 4)
        #expect(owners[WorkspaceInodeKey(stamp(4, .regular))] == "utils/Sub/b.swift")
        #expect(owners[WorkspaceInodeKey(stamp(5, .regular))] == "UtilsX")
    }

    /// An inode two names share is never treated as one owner's.
    @Test func sharedInodesHaveNoOwner() {
        let owners = workspaceUniqueInodeOwners([
            "a": stamp(7, .symlink),
            "b": stamp(7, .symlink),
            "c": stamp(8, .regular),
        ])
        #expect(owners[WorkspaceInodeKey(stamp(7, .symlink))] == nil)
        #expect(owners[WorkspaceInodeKey(stamp(8, .regular))] == "c")
    }
}

/// The workspace volume is case-sensitive; the saved tree under `/tmp` is
/// case-insensitive APFS. A case-only rename on the volume must publish as a
/// rename, never as an update of one inode followed by its retirement.
@Suite("Workspace publish case handling", .serialized)
struct WorkspacePublishCaseTests {
    @Test(arguments: [false, true])
    func caseOnlyFileRenamePublishesAsRename(_ edit: Bool) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let ws = tree.workspaceURL
        try Data("old\n".utf8).write(to: ws.appendingPathComponent("readme.md"))
        try Data("keep\n".utf8).write(to: ws.appendingPathComponent("other.txt"))
        let boundary = try establishWorkspaceInodeBoundary(at: ws.path).get()
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetained(boundary) }
        #expect(rename(ws.appendingPathComponent("readme.md").path, ws.appendingPathComponent("README.md").path) == 0)
        if edit {
            try Data("new\n".utf8).write(to: ws.appendingPathComponent("README.md"))
        }

        let result = boundary.publishAndRestore()
        #expect(isSuccess(result), "outcome: \(boundary.publishOutcome)")
        let names = try FileManager.default.contentsOfDirectory(atPath: ws.path).sorted()
        #expect(names == ["README.md", "other.txt"])
        let text = try? String(contentsOf: ws.appendingPathComponent("README.md"), encoding: .utf8)
        #expect(text == (edit ? "new\n" : "old\n"))
    }

    @Test func caseOnlyDirectoryRenameKeepsItsContents() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let ws = tree.workspaceURL
        let manager = FileManager.default
        try manager.createDirectory(at: ws.appendingPathComponent("Utils/Sub"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: ws.appendingPathComponent("Utils/a.swift"))
        try Data("b\n".utf8).write(to: ws.appendingPathComponent("Utils/Sub/b.swift"))
        try Data("gone\n".utf8).write(to: ws.appendingPathComponent("Utils/gone.swift"))
        let boundary = try establishWorkspaceInodeBoundary(at: ws.path).get()
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetained(boundary) }
        #expect(rename(ws.appendingPathComponent("Utils").path, ws.appendingPathComponent("utils").path) == 0)
        #expect(rename(ws.appendingPathComponent("utils/Sub").path, ws.appendingPathComponent("utils/sub").path) == 0)
        try Data("a2\n".utf8).write(to: ws.appendingPathComponent("utils/a.swift"))
        try Data("new\n".utf8).write(to: ws.appendingPathComponent("utils/sub/new.swift"))
        #expect(unlink(ws.appendingPathComponent("utils/gone.swift").path) == 0)

        let result = boundary.publishAndRestore()
        #expect(isSuccess(result), "outcome: \(boundary.publishOutcome)")
        #expect(try manager.contentsOfDirectory(atPath: ws.path) == ["utils"])
        #expect(try manager.contentsOfDirectory(atPath: ws.appendingPathComponent("utils").path).sorted()
            == ["a.swift", "sub"])
        #expect(try manager.contentsOfDirectory(atPath: ws.appendingPathComponent("utils/sub").path).sorted()
            == ["b.swift", "new.swift"])
        #expect(try String(contentsOf: ws.appendingPathComponent("utils/a.swift"), encoding: .utf8) == "a2\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("utils/sub/b.swift"), encoding: .utf8) == "b\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("utils/sub/new.swift"), encoding: .utf8) == "new\n")
    }

    /// `a.txt` and `A.txt` cannot both exist on the case-insensitive saved
    /// tree. That entry is refused by name; nothing is lost or written.
    @Test(arguments: [false, true])
    func caseVariantsOnTheVolumeAreRefused(_ bothNew: Bool) throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let ws = tree.workspaceURL
        if bothNew == false {
            try Data("a\n".utf8).write(to: ws.appendingPathComponent("a.txt"))
        }
        let boundary = try establishWorkspaceInodeBoundary(at: ws.path).get()
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetained(boundary) }
        if bothNew {
            try Data("a\n".utf8).write(to: ws.appendingPathComponent("a.txt"))
        }
        try Data("A\n".utf8).write(to: ws.appendingPathComponent("A.txt"))
        let before = try FileManager.default.contentsOfDirectory(atPath: boundary.savedPath).sorted()

        #expect(isSuccess(boundary.publishAndRestore()) == false)
        guard case .rejected(let rejections) = boundary.publishOutcome else {
            Issue.record("expected a rejection, got \(boundary.publishOutcome)")
            return
        }
        #expect(rejections.allSatisfy { $0.reason == .caseCollision })
        #expect(rejections.map(\.relative).contains("A.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.path).sorted() == before)
        if bothNew == false {
            #expect(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
        }
    }

    /// Publish does not rewrite a writable file the agent left alone: its
    /// inode and modification time survive, and only the edited file moves.
    @Test func untouchedWritableFileIsNotRewritten() throws {
        let tree = try ContainmentTree()
        defer { tree.tearDown() }
        let ws = tree.workspaceURL
        let still = ws.appendingPathComponent("still.txt").path
        try Data("same\n".utf8).write(to: URL(fileURLWithPath: still))
        try Data("old\n".utf8).write(to: ws.appendingPathComponent("edited.txt"))
        var past = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000_000, tv_usec: 0)]
        #expect(utimes(still, &past) == 0)
        var before = stat()
        #expect(lstat(still, &before) == 0)
        let boundary = try establishWorkspaceInodeBoundary(at: ws.path).get()
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetained(boundary) }
        try Data("new\n".utf8).write(to: ws.appendingPathComponent("edited.txt"))

        #expect(isSuccess(boundary.publishAndRestore()), "outcome: \(boundary.publishOutcome)")
        var after = stat()
        #expect(lstat(still, &after) == 0)
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(try String(contentsOfFile: still, encoding: .utf8) == "same\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("edited.txt"), encoding: .utf8) == "new\n")
    }

    /// On a case-sensitive saved tree both spellings are representable: a
    /// case-only rename is a create plus a remove, and variants coexist.
    @Test func caseSensitiveSavedTreePublishesVariantsAndRenames() throws {
        let host = try CaseSensitiveHostVolume()
        defer { host.tearDown() }
        let ws = host.mountPoint.appendingPathComponent("repo/ws", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: ws.appendingPathComponent("readme.md"))
        try Data("a\n".utf8).write(to: ws.appendingPathComponent("a.txt"))
        let boundary = try establishWorkspaceInodeBoundary(at: ws.path).get()
        defer { _ = boundary.discardAndRestore() }
        defer { removeRetained(boundary) }
        #expect(rename(ws.appendingPathComponent("readme.md").path, ws.appendingPathComponent("README.md").path) == 0)
        try Data("A\n".utf8).write(to: ws.appendingPathComponent("A.txt"))

        let result = boundary.publishAndRestore()
        #expect(isSuccess(result), "outcome: \(boundary.publishOutcome)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.path).sorted() == ["A.txt", "README.md", "a.txt"])
        #expect(try String(contentsOf: ws.appendingPathComponent("README.md"), encoding: .utf8) == "old\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("A.txt"), encoding: .utf8) == "A\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
    }
}

/// A case-sensitive APFS volume standing in for a case-sensitive host
/// filesystem. Mounted under `/tmp`; detached and deleted by `tearDown`.
struct CaseSensitiveHostVolume {
    let image: String
    let mountPoint: URL

    init() throws {
        let token = UUID().uuidString
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("rv-cshost-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        image = root.path + ".sparseimage"
        mountPoint = root
        try Self.run([
            "/usr/bin/hdiutil", "create", "-size", "64m", "-fs", "Case-sensitive APFS",
            "-volname", "rvcs", "-type", "SPARSE", "-quiet", image,
        ])
        do {
            try Self.run([
                "/usr/bin/hdiutil", "attach", "-nobrowse", "-owners", "on",
                "-mountpoint", root.path, "-quiet", image,
            ])
        } catch {
            unlink(image)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func tearDown() {
        _ = try? Self.run(["/usr/bin/hdiutil", "detach", "-force", "-quiet", mountPoint.path])
        unlink(image)
        rmdir(mountPoint.path)
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private func isSuccess(_ result: Result<Void, IsolationApplyError>) -> Bool {
    if case .success = result { return true }
    return false
}

private func removeRetained(_ boundary: WorkspaceInodeBoundary) {
    if let retained = boundary.retainedRejectedImagePath { unlink(retained) }
}
#endif
