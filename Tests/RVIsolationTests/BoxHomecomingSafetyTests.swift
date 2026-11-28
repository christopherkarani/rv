#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVIsolation

/// Regressions from the L5 review's probes: what `rv box done` does to
/// real folders when a write fails, when you made or edited folders
/// outside the box, when the box changed a folder's mode, and when the box
/// pointed a link you also changed out of the project.
@Suite("rv box done keeps every version on real folders", .serialized)
struct BoxHomecomingSafetyTests {
    struct Fixture {
        let root: URL
        var saved: String { root.path + "/.rv-saved-probe" }
        var box: String { root.path + "/app" }
        var trash: BoxTrash { BoxTrash(root: root.appendingPathComponent("box-trash")) }
        var start = Date()

        init(_ original: [String: String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-box-safety-\(UUID().uuidString)")
            for side in ["/.rv-saved-probe", "/app"] {
                try FileManager.default.createDirectory(atPath: root.path + side, withIntermediateDirectories: true)
                for (path, text) in original { try Self.put(text, root.path + side + "/" + path) }
            }
            Thread.sleep(forTimeInterval: 0.05)
            start = Date()
            Thread.sleep(forTimeInterval: 0.05)
        }

        static func put(_ text: String, _ path: String) throws {
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }

        func review() throws -> BoxReview {
            try BoxHomecomingScan.review(savedRoot: saved, boxRoot: box, startedAt: start).get()
        }

        func run(_ plan: BoxHomePlan) -> BoxHomecomingApply.Outcome {
            BoxHomecomingApply.apply(plan, savedRoot: saved, boxRoot: box, project: box, trash: trash, now: start)
        }

        func text(_ path: String) -> String? {
            FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }

        func mode(_ path: String) -> mode_t {
            var info = stat()
            lstat(path, &info)
            return info.st_mode & 0o7777
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    /// Probe `failedRestoreIsPhantomRemoval`: the restore removed the
    /// box's file and then failed to copy yours, leaving neither. The
    /// copy is now written beside it and renamed over it, so a failed
    /// copy leaves the box's version where it was.
    @Test func aRestoreThatFailsLeavesTheBoxsVersion() throws {
        let fixture = try Fixture(["a.txt": "yours\n"])
        defer { fixture.clean() }
        try Fixture.put("the box's\n", fixture.box + "/a.txt")
        // A saved name that can't be copied makes the copy fail.
        unlink(fixture.saved + "/a.txt")
        #expect(mkfifo(fixture.saved + "/a.txt", 0o644) == 0)
        let outcome = fixture.run(BoxHomePlan(steps: [.restore("a.txt")], keptFiles: 0, droppedFiles: 1))
        #expect(outcome == .failed(path: "a.txt", trash: nil))
        #expect(fixture.text(fixture.box + "/a.txt") == "the box's\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.box) == ["a.txt"])
    }

    @Test func aRestoreReplacesTheBoxsVersionInPlace() throws {
        let fixture = try Fixture(["src/a.txt": "yours\n"])
        defer { fixture.clean() }
        try Fixture.put("the box's\n", fixture.box + "/src/a.txt")
        let plan = BoxHomecoming.plan(try fixture.review(), choice: .dropAll)
        #expect(plan.steps == [.trash("src/a.txt"), .restore("src/a.txt")])
        guard case .applied(let trash?) = fixture.run(plan) else {
            Issue.record("drop must apply")
            return
        }
        #expect(fixture.text(fixture.box + "/src/a.txt") == "yours\n")
        #expect(fixture.text(trash.path + "/files/src/a.txt") == "the box's\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.box + "/src") == ["a.txt"])
    }

    /// A copy a stopped run left behind is listed and dropped, never
    /// brought home.
    @Test func anUnfinishedCopyIsDropped() throws {
        let fixture = try Fixture(["a.txt": "a\n"])
        defer { fixture.clean() }
        let leftover = BoxHomecomingApply.unfinishedPrefix + UUID().uuidString
        try Fixture.put("half", fixture.box + "/" + leftover)
        let review = try fixture.review()
        #expect(review.items.isEmpty)
        #expect(review.refused.map(\.kind) == [.cannotComeHome(.unfinishedCopy)])
        guard case .applied = fixture.run(BoxHomecoming.plan(review, choice: .keepAll)) else {
            Issue.record("apply failed")
            return
        }
        #expect(fixture.exists(fixture.box + "/" + leftover) == false)
    }

    /// Probe `escapingLinkPlacedBeside`: both changed a link and the box's
    /// points out of the project. It was placed beside yours, where
    /// publish then refused the whole close. It is now refused itself.
    @Test func anOutwardLinkYouBothChangedIsRefused() throws {
        var fixture = try Fixture(["a": "a\n", "b": "b\n"])
        defer { fixture.clean() }
        symlink("a", fixture.saved + "/lnk")
        symlink("a", fixture.box + "/lnk")
        fixture.start = Date()
        Thread.sleep(forTimeInterval: 0.05)
        unlink(fixture.saved + "/lnk")
        symlink("b", fixture.saved + "/lnk")
        unlink(fixture.box + "/lnk")
        symlink("/etc/passwd", fixture.box + "/lnk")
        let review = try fixture.review()
        #expect(review.yours.isEmpty)
        #expect(review.refused.map(\.relative) == ["lnk"])
        #expect(review.refused.first?.kind == .cannotComeHome(.linkLeavesProject))
        guard case .applied(let trash?) = fixture.run(BoxHomecoming.plan(review, choice: .keepAll)) else {
            Issue.record("apply failed")
            return
        }
        #expect(BoxFileRead.linkTarget(fixture.box + "/lnk") == "b")
        #expect(fixture.exists(fixture.box + "/lnk.from-box") == false)
        #expect(BoxFileRead.linkTarget(trash.path + "/files/lnk") == "/etc/passwd")
    }

    /// Probe `yourNewFolderReadsAsRemoved`: a folder you made outside the
    /// box read as one the box removed, and keep-all failed for good on
    /// the file in it.
    @Test func aFolderYouMadeOutsideTheBoxIsYours() throws {
        let fixture = try Fixture(["a": "a\n"])
        defer { fixture.clean() }
        try Fixture.put("mine\n", fixture.saved + "/mine/n.txt")
        let review = try fixture.review()
        #expect(review.items.isEmpty)
        #expect(review.yours.map(\.relative) == ["mine", "mine/n.txt"])
        #expect(review.yours.allSatisfy { $0.kind == .yoursKept })
        guard case .applied = fixture.run(BoxHomecoming.plan(review, choice: .keepAll)) else {
            Issue.record("keep all must apply")
            return
        }
        #expect(fixture.text(fixture.box + "/mine/n.txt") == "mine\n")
        #expect(fixture.mode(fixture.box + "/mine") == fixture.mode(fixture.saved + "/mine"))
        #expect(try fixture.review().isEmpty)
    }

    /// Probe `yourEditInRemovedFolder`: the box removed a folder and you
    /// edited a file in it. Your file comes back with its folder; the
    /// box's other removals there are still yours to keep or drop.
    @Test(arguments: [BoxHomeChoice.keepAll, .dropAll])
    func yourEditInAFolderTheBoxRemoved(choice: BoxHomeChoice) throws {
        let fixture = try Fixture(["docs/a.md": "a\n", "docs/b.md": "b\n", "c": "c\n"])
        defer { fixture.clean() }
        try FileManager.default.removeItem(atPath: fixture.box + "/docs")
        try Fixture.put("mine\n", fixture.saved + "/docs/a.md")
        let review = try fixture.review()
        #expect(review.items.map(\.id) == ["docs/b.md"])
        #expect(review.items.first?.kind == .removed)
        #expect(review.yours.map(\.relative) == ["docs/a.md"])
        guard case .applied = fixture.run(BoxHomecoming.plan(review, choice: choice)) else {
            Issue.record("apply failed")
            return
        }
        #expect(fixture.text(fixture.box + "/docs/a.md") == "mine\n")
        #expect(fixture.exists(fixture.box + "/docs/b.md") == (choice == .dropAll))
    }

    /// Probe `folderModeSurvivesDrop`: an agent's chmod on a folder was
    /// not in the review, and drop left it for publish to bring home.
    @Test func aFolderModeChangeIsListed_andDropUndoesIt() throws {
        let fixture = try Fixture(["bin/run.sh": "echo\n"])
        defer { fixture.clean() }
        let before = fixture.mode(fixture.saved + "/bin")
        chmod(fixture.box + "/bin", 0o777)
        let review = try fixture.review()
        #expect(review.items.map(\.id) == ["bin/"])
        #expect(review.items.first?.shape == .folderMode)
        let keep = BoxHomecoming.plan(review, choice: .keepAll)
        #expect(keep.steps.isEmpty)
        let drop = BoxHomecoming.plan(review, choice: .dropAll)
        #expect(drop.steps == [.restore("bin")])
        guard case .applied = fixture.run(drop) else {
            Issue.record("drop must apply")
            return
        }
        #expect(fixture.mode(fixture.box + "/bin") == before)
        #expect(try fixture.review().isEmpty)
    }

    /// A folder you deleted outside the box, which the box left alone,
    /// read as one the box made. It stays deleted.
    @Test func aFolderYouDeletedStaysDeleted() throws {
        let fixture = try Fixture(["old/x.txt": "x\n", "keep": "k\n"])
        defer { fixture.clean() }
        try FileManager.default.removeItem(atPath: fixture.saved + "/old")
        let review = try fixture.review()
        #expect(review.items.isEmpty)
        #expect(review.yours.map(\.relative) == ["old", "old/x.txt"])
        guard case .applied = fixture.run(BoxHomecoming.plan(review, choice: .keepAll)) else {
            Issue.record("apply failed")
            return
        }
        #expect(fixture.exists(fixture.box + "/old") == false)
    }

    /// ... unless the box put work in it: then it is the box's new folder.
    @Test func aFolderYouDeletedThatTheBoxUsedIsTheBoxs() throws {
        let fixture = try Fixture(["old/x.txt": "x\n", "keep": "k\n"])
        defer { fixture.clean() }
        try FileManager.default.removeItem(atPath: fixture.saved + "/old")
        try Fixture.put("new\n", fixture.box + "/old/new.txt")
        let review = try fixture.review()
        #expect(review.items.map(\.id) == ["old/"])
        #expect(review.items.first?.shape == .newFolder)
        #expect(review.yours.map(\.relative) == ["old/x.txt"])
        guard case .applied = fixture.run(BoxHomecoming.plan(review, choice: .dropAll)) else {
            Issue.record("apply failed")
            return
        }
        #expect(fixture.exists(fixture.box + "/old") == false)
    }

    /// A restore never makes a folder through a link the box planted.
    @Test func aRestoreNeverMakesFoldersThroughALink() throws {
        let fixture = try Fixture(["docs/a.md": "a\n"])
        defer { fixture.clean() }
        let outside = fixture.root.path + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: fixture.box + "/docs")
        symlink(outside, fixture.box + "/docs")
        let outcome = fixture.run(BoxHomePlan(steps: [.restore("docs/a.md")], keptFiles: 0, droppedFiles: 1))
        #expect(outcome == .failed(path: "docs/a.md", trash: nil))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside).isEmpty)
    }

    /// `NSString`'s path methods trapped on one-character names on Linux.
    @Test(arguments: [("a", "", "a"), ("a/b", "a", "b"), ("x/y/z.txt", "x/y", "z.txt"), ("-", "", "-")])
    func pathsSplitByHand(path: String, parent: String, name: String) {
        #expect(BoxPath.parent(path) == parent)
        #expect(BoxPath.name(path) == name)
    }

    @Test func oneCharacterNamesComeHome() throws {
        let fixture = try Fixture(["x": "x\n", "y/z": "z\n"])
        defer { fixture.clean() }
        try Fixture.put("box x\n", fixture.box + "/x")
        try Fixture.put("box z\n", fixture.box + "/y/z")
        guard case .applied = fixture.run(BoxHomecoming.plan(try fixture.review(), choice: .dropAll)) else {
            Issue.record("apply failed")
            return
        }
        #expect(fixture.text(fixture.box + "/x") == "x\n")
        #expect(fixture.text(fixture.box + "/y/z") == "z\n")
    }

    // MARK: the snapshot publish checks

    static func stamps(_ root: String) -> BoxSnapshot {
        guard case .success(let stamps) = BoxHomecomingScan.stamps(root) else { return BoxSnapshot(stamps: [:]) }
        return BoxSnapshot(stamps: stamps)
    }

    /// An app's safe-save (a new file renamed over the name) gives it a
    /// new inode, which publish refuses. The review lists it as replaced.
    @Test func aSafeSaveOutsideTheBoxIsReplaced() throws {
        let fixture = try Fixture(["notes.md": "n\n", "same.md": "s\n"])
        defer { fixture.clean() }
        let snapshot = Self.stamps(fixture.saved)
        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: fixture.saved + "/notes.md"), options: .atomic)
        try Fixture.put("same, edited in place\n", fixture.saved + "/same.md")
        try Fixture.put("new\n", fixture.saved + "/new.md")
        let review = try BoxHomecomingScan.review(
            savedRoot: fixture.saved, boxRoot: fixture.box, startedAt: fixture.start, snapshot: snapshot).get()
        #expect(review.replaced == ["notes.md"])
        #expect(review.isEmpty == false)
    }

    @Test func theSnapshotIsReadOnlyFromTheRecordedFile() throws {
        let fixture = try Fixture(["a": "a\n"])
        defer { fixture.clean() }
        let path = fixture.root.path + "/snapshot.json"
        try Data(#"{"entries":[{"device":1,"inode":2,"kind":"regular","linkCount":1,"path":"a"}]}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        var info = stat()
        lstat(path, &info)
        let read = BoxSnapshot.read(path: path, device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        #expect(read == BoxSnapshot(stamps: ["a": BoxInodeStamp(device: 1, inode: 2, links: 1, kind: .regular)]))
        #expect(BoxSnapshot.read(path: path, device: UInt64(info.st_dev), inode: UInt64(info.st_ino) + 1) == nil)
    }

    @Test func theRootsMustBeTheRecordedOnes() throws {
        let fixture = try Fixture(["a": "a\n"])
        defer { fixture.clean() }
        var saved = stat()
        var box = stat()
        lstat(fixture.saved, &saved)
        stat(fixture.box, &box)
        let source = BoxHomecomingSource(
            project: fixture.box, savedRoot: fixture.saved, startedAt: fixture.start,
            saved: (UInt64(saved.st_dev), UInt64(saved.st_ino)), volumeDevice: UInt64(box.st_dev))
        #expect(source.rootsMatch(boxRoot: fixture.box))
        var moved = source
        moved.saved = (UInt64(saved.st_dev), UInt64(saved.st_ino) + 1)
        #expect(moved.rootsMatch(boxRoot: fixture.box) == false)
        var elsewhere = source
        elsewhere.volumeDevice = UInt64(box.st_dev) + 1
        #expect(elsewhere.rootsMatch(boxRoot: fixture.box) == false)
    }
}
