import Foundation
import Testing
@testable import RVIsolation

/// L5, the review on the way home: what changed, how it groups, and which
/// edits each choice makes to the box before it closes. Pure.
@Suite("rv box done decides what comes home")
struct BoxHomecomingTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let before = start.addingTimeInterval(-60)
    static let after = start.addingTimeInterval(60)

    static func file(_ at: Date = before, size: UInt64 = 10, mode: UInt16 = 0o644) -> BoxTreeEntry {
        BoxTreeEntry(kind: .file, size: size, mode: mode, changedAt: at)
    }

    static let folder = BoxTreeEntry(kind: .directory, mode: 0o755, changedAt: after)

    static func classify(
        _ relative: String = "src/a.ts", saved: BoxTreeEntry?, box: BoxTreeEntry?, same: Bool = false,
        lines: BoxLineCount? = BoxLineCount(added: 3, removed: 1), inside: Bool = true
    ) -> BoxPathChange.Kind? {
        BoxHomecoming.classify(
            relative, saved: saved, box: box, sameContent: same, lines: lines, startedAt: start,
            linkStaysInside: { _, _ in inside })?.kind
    }

    // MARK: classify

    @Test func theBoxsOwnEditsAreChoosable() {
        #expect(Self.classify(saved: Self.file(), box: Self.file(Self.after)) == .changed)
        #expect(Self.classify(saved: nil, box: Self.file(Self.after)) == .added)
        #expect(Self.classify(saved: Self.file(), box: nil) == .removed)
        #expect(Self.classify(saved: Self.file(), box: Self.file(Self.after), same: true) == nil)
        #expect(Self.classify(saved: Self.file(), box: Self.file(Self.after, mode: 0o755), same: true) == .changed)
        #expect(Self.classify(saved: Self.folder, box: Self.folder) == nil)
    }

    /// The rule: bringing changes home never overwrites newer human edits.
    @Test func yourNewerEditsAreNeverOverwritten() {
        // You changed it outside after the box started; the box left it.
        #expect(Self.classify(saved: Self.file(Self.after), box: Self.file()) == .yoursKept)
        // Both changed it: both are kept.
        #expect(Self.classify(saved: Self.file(Self.after), box: Self.file(Self.after)) == .bothKept)
        // You changed it, the box removed it: yours stays.
        #expect(Self.classify(saved: Self.file(Self.after), box: nil) == .yoursKept)
        // You removed it after the box started; the box's copy is untouched.
        #expect(Self.classify(saved: nil, box: Self.file()) == .yoursKept)
        // The same bytes on both sides are no conflict.
        #expect(Self.classify(saved: Self.file(Self.after), box: Self.file(Self.after), same: true) == nil)
    }

    /// Folders follow the same rule as files: a change the box made is a
    /// choice, a change made outside it after it started is yours.
    @Test func foldersFollowTheSameRule() {
        let untouched = BoxTreeEntry(kind: .directory, mode: 0o755, changedAt: Self.before)
        let opened = BoxTreeEntry(kind: .directory, mode: 0o777, changedAt: Self.after)
        // The box changed a folder's mode.
        #expect(Self.classify(saved: untouched, box: opened) == .changed)
        // You touched the folder outside the box too: your mode stays.
        #expect(Self.classify(saved: Self.folder, box: opened) == .yoursKept)
        // A folder you made outside the box.
        #expect(Self.classify(saved: Self.folder, box: nil) == .yoursKept)
        #expect(Self.classify(saved: untouched, box: nil) == .removed)
        // A folder you removed outside the box, which the box left alone.
        #expect(Self.classify(saved: nil, box: untouched) == .yoursKept)
        #expect(Self.classify(saved: nil, box: Self.folder) == .added)
    }

    @Test func aLinkTheBoxPointedOutIsRefusedEvenWhenYouChangedItToo() {
        let yours = BoxTreeEntry(kind: .symlink(target: "b"), changedAt: Self.after)
        let boxs = BoxTreeEntry(kind: .symlink(target: "/etc/passwd"), changedAt: Self.after)
        #expect(Self.classify("lnk", saved: yours, box: boxs, inside: false) == .cannotComeHome(.linkLeavesProject))
        #expect(Self.classify("lnk", saved: yours, box: boxs, inside: true) == .bothKept)
    }

    @Test func whatPublishCannotCopyIsRefusedAndAKindChangeBlocks() {
        let fifo = BoxTreeEntry(kind: .special, changedAt: Self.after)
        #expect(Self.classify(saved: nil, box: fifo) == .cannotComeHome(.special))
        let link = BoxTreeEntry(kind: .symlink(target: "/usr/bin/python3"), changedAt: Self.after)
        #expect(Self.classify(".venv/bin/python3", saved: nil, box: link, inside: false)
            == .cannotComeHome(.linkLeavesProject))
        #expect(Self.classify(".venv/bin/python3", saved: nil, box: link, inside: true) == .added)
        #expect(Self.classify(saved: Self.file(), box: Self.folder) == .kindChanged)
    }

    // MARK: review

    static func change(
        _ relative: String, _ kind: BoxPathChange.Kind, folder: Bool = false,
        lines: BoxLineCount? = BoxLineCount(added: 1, removed: 0)
    ) -> BoxPathChange {
        let entry = folder ? Self.folder : Self.file(Self.after)
        switch kind {
        case .added:
            return BoxPathChange(relative: relative, kind: kind, saved: nil, box: entry, lines: folder ? nil : lines)
        case .removed:
            return BoxPathChange(relative: relative, kind: kind, saved: entry, box: nil, lines: folder ? nil : lines)
        default:
            return BoxPathChange(relative: relative, kind: kind, saved: entry, box: entry, lines: lines)
        }
    }

    @Test func newFoldersAndGitDataComeAsOneLineEach_biggestFirst() {
        let review = BoxHomecoming.review([
            Self.change("src/clock.ts", .changed, lines: BoxLineCount(added: 38, removed: 4)),
            Self.change("test/clock.spec.ts", .changed, lines: BoxLineCount(added: 22, removed: 17)),
            Self.change("node_modules", .added, folder: true),
            Self.change("node_modules/left-pad", .added, folder: true),
            Self.change("node_modules/left-pad/index.js", .added),
            Self.change("node_modules/left-pad/package.json", .added),
            Self.change(".git/index", .changed, lines: nil),
            Self.change(".git/refs/heads/main", .changed),
        ], names: [], startedAt: Self.start)
        #expect(review.items.map(\.id) == ["src/clock.ts", "test/clock.spec.ts", "node_modules/", ".git/"])
        #expect(review.items.map(\.shape) == [.file, .file, .newFolder, .git])
        #expect(review.items[2].fileCount == 2)
        #expect(review.fileCount == 6)
        #expect(review.lines == BoxLineCount(added: 63, removed: 21))
    }

    @Test func theBoxsVersionTakesAFreeNameBesideYours() {
        let review = BoxHomecoming.review(
            [Self.change("src/app.ts", .bothKept)],
            names: ["src/app.ts", "src/app.ts.from-box"], startedAt: Self.start)
        #expect(review.items.isEmpty)
        #expect(review.yours.first?.beside == "src/app.ts.from-box-2")
    }

    // MARK: plan

    static let mixed = BoxHomecoming.review([
        Self.change("src/new.ts", .added),
        Self.change("src/old.ts", .changed),
        Self.change("docs/gone.md", .removed),
        Self.change("build", .added, folder: true),
        Self.change("build/out.js", .added),
        Self.change("notes.md", .yoursKept),
        Self.change("src/app.ts", .bothKept),
    ], names: [], startedAt: Self.start)

    @Test func keepingAllStillKeepsYourNewerEdits() {
        let plan = BoxHomecoming.plan(Self.mixed, choice: .keepAll)
        #expect(plan.steps == [
            .placeBeside("src/app.ts", as: "src/app.ts.from-box"),
            .restore("notes.md"),
            .restore("src/app.ts"),
        ])
        #expect(plan.keptFiles == 4)
        #expect(plan.droppedFiles == 0)
        #expect(plan.trashed == 0)
    }

    @Test func droppingCopiesTheBoxsWorkToTheTrashBeforeUndoingIt() {
        let plan = BoxHomecoming.plan(Self.mixed, choice: .dropAll)
        #expect(plan.steps == [
            .trash("build/out.js"), .trash("src/new.ts"), .trash("src/old.ts"),
            .placeBeside("src/app.ts", as: "src/app.ts.from-box"),
            .remove("build/out.js"), .restore("docs/gone.md"), .remove("src/new.ts"), .restore("src/old.ts"),
            .restore("notes.md"), .restore("src/app.ts"),
            .removeFolder("build"),
        ])
        #expect(plan.droppedFiles == 4)
        #expect(plan.keptFiles == 0)
    }

    @Test func pickingDropsOnlyWhatWasNotPicked() {
        let plan = BoxHomecoming.plan(Self.mixed, choice: .keep(["src/old.ts", "build/"]))
        #expect(plan.keptFiles == 2)
        #expect(plan.droppedFiles == 2)
        #expect(plan.steps.contains(.trash("src/new.ts")))
        #expect(plan.steps.contains(.restore("docs/gone.md")))
        #expect(plan.steps.contains(.trash("src/old.ts")) == false)
        #expect(plan.steps.contains(.removeFolder("build")) == false)
    }

    /// Unsaved work is never lost: no step undoes the box's own version of
    /// a file before a trash step has copied it, whatever the choice.
    @Test(arguments: [BoxHomeChoice.keepAll, .dropAll, .keep(["src/old.ts"]), .keep([])])
    func nothingTheBoxWroteIsUndoneWithoutACopy(choice: BoxHomeChoice) {
        let plan = BoxHomecoming.plan(Self.mixed, choice: choice)
        let boxWrote = Set(Self.mixed.items.flatMap(\.changes).filter { $0.box != nil && $0.isFolder == false }
            .map(\.relative))
        for (index, step) in plan.steps.enumerated() {
            switch step {
            case .remove(let path), .restore(let path):
                guard boxWrote.contains(path) else { continue }
                #expect(plan.steps[..<index].contains(.trash(path)), "\(path) undone before its copy")
            default:
                continue
            }
        }
    }

    @Test func refusedLinksGoToTheTrash_specialFilesAreRemoved() {
        let link = BoxTreeEntry(kind: .symlink(target: "/usr/bin/python3"), changedAt: Self.after)
        let fifo = BoxTreeEntry(kind: .special, changedAt: Self.after)
        let review = BoxHomecoming.review([
            BoxPathChange(relative: ".venv/bin/python3", kind: .cannotComeHome(.linkLeavesProject), saved: nil, box: link),
            BoxPathChange(relative: "run/sock", kind: .cannotComeHome(.special), saved: nil, box: fifo),
        ], names: [], startedAt: Self.start)
        let plan = BoxHomecoming.plan(review, choice: .keepAll)
        #expect(plan.steps == [.trash(".venv/bin/python3"), .remove(".venv/bin/python3"), .remove("run/sock")])
    }

    // MARK: line counts

    @Test func lineCountsMatchGitNumstat() {
        func count(_ old: String?, _ new: String?) -> BoxLineCount? {
            BoxLineDiff.count(old: old.map { Data($0.utf8) }, new: new.map { Data($0.utf8) })
        }
        #expect(count("a\nb\nc\n", "a\nB\nc\nd\n") == BoxLineCount(added: 2, removed: 1))
        #expect(count(nil, "one\ntwo\n") == BoxLineCount(added: 2, removed: 0))
        #expect(count("one\ntwo", nil) == BoxLineCount(added: 0, removed: 2))
        #expect(count("same\n", "same\n") == .zero)
        #expect(count("x\ny\nz\n", "z\nx\ny\n") == BoxLineCount(added: 1, removed: 1))
        #expect(BoxLineDiff.count(old: Data([0x00, 0x01]), new: Data("text".utf8)) == nil)
    }

    @Test func aHugeRewriteFallsBackToALowerBoundQuickly() {
        let old = (0..<20_000).map { "line \($0)" }.joined(separator: "\n")
        let new = (0..<20_000).map { "line \($0 * 7 % 20_000) changed" }.joined(separator: "\n")
        let counted = BoxLineDiff.count(old: Data(old.utf8), new: Data(new.utf8))
        #expect(counted == BoxLineCount(added: 20_000, removed: 20_000))
    }

    // MARK: source

    @Test func theSavedTreeComesFromTheBoxsCreatedRecordOnly() {
        let workspace = UUID()
        func record(_ saved: String, kind: WorkspaceLifecycleRecord.Kind = .created, id: UUID = workspace) -> WorkspaceLifecycleRecord {
            WorkspaceLifecycleRecord(
                kind: kind, workspace: id, originalPath: "/Users/chris/code/app", protectedPath: "/Users/chris/code/app",
                volumeDevice: 1, disk: "/dev/disk9", runtime: nil, recordedAt: Self.start,
                identity: WorkspaceDurableIdentity(
                    savedPath: saved, savedDevice: 1, savedInode: 2, quarantinePath: "/q", volumeDevice: 3,
                    disk: "/dev/disk9", mountSource: "/dev/disk9s1", imagePath: nil, imageDevice: nil, imageInode: nil,
                    lockPath: "/l", lockDevice: 1, lockInode: 1, ownerToken: UUID(), snapshotPath: "/s",
                    snapshotDevice: 1, snapshotInode: 1))
        }
        let good = "/Users/chris/code/.rv-saved-0123456789ab"
        #expect(BoxHomecomingSource.find(workspace: workspace, in: [record(good)])
            == BoxHomecomingSource(
                project: "/Users/chris/code/app", savedRoot: good, startedAt: Self.start,
                saved: (device: 1, inode: 2), volumeDevice: 3))
        #expect(BoxHomecomingSource.find(workspace: workspace, in: [record(good, id: UUID())]) == nil)
        #expect(BoxHomecomingSource.find(workspace: workspace, in: [record(good, kind: .runtimeStarted)]) == nil)
        // A saved path anywhere but beside the project, under rv's name, is not trusted.
        #expect(BoxHomecomingSource.find(workspace: workspace, in: [record("/Users/chris/.ssh")]) == nil)
        #expect(BoxHomecomingSource.find(workspace: workspace, in: [record("/tmp/.rv-saved-0123456789ab")]) == nil)
    }
}
