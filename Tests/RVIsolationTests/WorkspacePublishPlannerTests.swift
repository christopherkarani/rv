#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVIsolation

/// The publish planner decided against an in-memory fake of the volume and
/// saved trees. No disk image is mounted.
@Suite("Workspace publish planner")
struct WorkspacePublishPlannerTests {
    // MARK: AC-B02: facts call sequence

    /// The mixed fixture: two symlinks (one unchanged, one new), a case-only
    /// rename (`Readme.md` → `README.md`), a new directory, a new file, an
    /// updated file, and a removed directory with one file in it.
    ///
    /// The expected sequence was written by hand from `planPublish`,
    /// `planCaseRenames` and `removedSubtreeIsOwned` as they stood in
    /// `WorkspaceInodeBoundary` at 245aa9b1, before the planner moved out.
    /// The symlink loop walks `volumeEntries` in dictionary order, as that
    /// code did, so the expectation takes its two symlinks in that order.
    @Test func mixedFixtureAsksFactsInTheOrderThePreExtractionCodeDid() {
        let fixture = PlannerFixture.mixed()
        let trees = fixture.trees()
        let result = fixture.plan(trees)

        // The symlink loop's order is unspecified by design: it is the
        // dictionary's iteration order, as at 245aa9b1. The test mirrors
        // that order from the same dictionary rather than pinning one.
        let symlinks = fixture.volume.compactMap { $0.value.kind == .symlink ? $0.key : nil }
        var respelled = fixture.snapshot
        respelled["README.md"] = respelled.removeValue(forKey: "Readme.md")
        var expected: [FakeTrees.Call] = symlinks.flatMap { [.shouldStop, .volumeLink($0)] }
        expected += [
            .savedFoldsCase,
            // planCaseRenames: the snapshot is published, then one pass.
            .publishStampsChanged(fixture.snapshot),
            .shouldStop, .savedStamp("README.md"),
            .publishStampsChanged(respelled),
            .shouldStop, // link: has a stamp
            .shouldStop, // src: has a stamp
            .shouldStop, // src/a.swift: has a stamp
            .shouldStop, .savedStamp("src/gen"),
            .shouldStop, .savedStamp("src/new-link"),
            .shouldStop, .savedStamp("src/new.swift"),
            // On-volume names, depth then name.
            .shouldStop, .savedStamp("README.md"),
            .shouldStop, .savedStamp("link"), .savedLink("link"),
            .shouldStop, .savedStamp("src"),
            .shouldStop, .savedStamp("src/a.swift"),
            .shouldStop, .savedStamp("src/gen"),
            .shouldStop, .savedStamp("src/new-link"),
            .shouldStop, .savedStamp("src/new.swift"),
            // Snapshot names missing from the volume, sorted.
            .shouldStop, .savedStamp("old"),
            .shouldStop, .savedStamp("old/x.txt"),
            // Retires: only the removed directory's root is checked.
            .removedSubtreeOwned("old", ["old", "old/x.txt"]),
        ]
        #expect(trees.calls == expected)
        #expect(trees.savedStampSawStaleStamps == false)
        #expect(result.stamps == respelled)
    }

    // MARK: AC-B01: step order

    @Test func mixedPlanStepsRunInPublishOrder() {
        let fixture = PlannerFixture.mixed()
        let result = fixture.plan(fixture.trees())
        #expect(result.plan == .planned([
            .renameCase(from: "Readme.md", to: "README.md"),
            .makeDirectory("src/gen"),
            .stageFile("src/new.swift", 0o644),
            .updateFile("README.md", 0o644),
            .updateFile("src/a.swift", 0o600),
            .createSymlink("src/new-link", target: "a.swift"),
            .installFile("src/new.swift"),
            .retire("old"),
            .setDirectoryMode("src/gen", 0o700),
            .setDirectoryMode("src", 0o755),
        ]))
    }

    // MARK: AC-B01: rejections

    @Test func specialEntriesAreUnsupported() {
        let fixture = PlannerFixture(volume: [:], snapshot: [:], special: ["pipe", "dev/sock"])
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "dev/sock", reason: .unsupportedFileType),
            WorkspacePublishRejection(relative: "pipe", reason: .unsupportedFileType),
        ]))
    }

    @Test func unreadableVolumeLinkIsUnreadable() {
        let fixture = PlannerFixture(volume: ["l": .symlink(ino: 1)], snapshot: [:])
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "l", reason: .unreadable),
        ]))
    }

    @Test func unreadableSavedLinkIsUnreadable() {
        var fixture = PlannerFixture(volume: ["l": .symlink(ino: 9)], snapshot: ["l": .stamp(5, .symlink)])
        fixture.volumeLinks = ["l": "x"]
        fixture.saved = ["l": .stamp(5, .symlink)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "l", reason: .unreadable),
        ]))
    }

    @Test func takenStageNameIsUnreadable() {
        let stage = workspacePublishStageName(for: "new.txt")
        var fixture = PlannerFixture(
            volume: ["new.txt": .file(ino: 1)],
            snapshot: [stage: .stamp(4, .regular)]
        )
        fixture.saved = [stage: .stamp(4, .regular)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "new.txt", reason: .unreadable),
        ]))
    }

    @Test(arguments: [true, false])
    func caseVariantsCollideOnlyOnAFoldingSavedTree(folds: Bool) {
        var fixture = PlannerFixture(volume: ["A.txt": .file(ino: 1), "a.txt": .file(ino: 2)], snapshot: [:])
        fixture.foldsCase = folds
        let plan = fixture.plan(fixture.trees()).plan
        if folds {
            #expect(plan == .rejected([
                WorkspacePublishRejection(relative: "A.txt", reason: .caseCollision),
                WorkspacePublishRejection(relative: "a.txt", reason: .caseCollision),
            ]))
        } else {
            #expect(plan == .planned([
                .stageFile("A.txt", 0o644), .stageFile("a.txt", 0o644),
                .installFile("A.txt"), .installFile("a.txt"),
            ]))
        }
    }

    @Test func caseRenameOntoAVolumeNameThatStillExistsCollides() {
        // `readme.md` is captured and still on the volume. `README.md` is new
        // and its saved lookup reaches the captured inode. With no up-front
        // collision (the tree reported no folding), respelling would drop a
        // name the volume keeps.
        var fixture = PlannerFixture(
            volume: ["README.md": .file(ino: 1), "readme.md": .file(ino: 2)],
            snapshot: ["readme.md": .stamp(10, .regular)]
        )
        fixture.foldsCase = false
        fixture.saved = ["README.md": .stamp(10, .regular), "readme.md": .stamp(10, .regular)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "README.md", reason: .caseCollision),
        ]))
    }

    @Test func kindChangeIsRefused() {
        var fixture = PlannerFixture(volume: ["x": .directory(ino: 1)], snapshot: ["x": .stamp(5, .regular)])
        fixture.saved = ["x": .stamp(5, .regular)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "x", reason: .kindChanged),
        ]))
    }

    @Test(arguments: [false, true])
    func escapingSymlinkIsRefused(existing: Bool) {
        var fixture = PlannerFixture(
            volume: ["l": .symlink(ino: 1)],
            snapshot: existing ? ["l": .stamp(5, .symlink)] : [:]
        )
        fixture.volumeLinks = ["l": "../outside"]
        if existing {
            fixture.saved = ["l": .stamp(5, .symlink)]
            fixture.savedLinks = ["l": "inside"]
        }
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "l", reason: .symlinkEscapesWorkspace),
        ]))
    }

    @Test func replacedSavedInodeIsRefused() {
        var fixture = PlannerFixture(
            volume: ["f": .file(ino: 1)],
            snapshot: ["f": .stamp(5, .regular), "gone": .stamp(6, .regular)]
        )
        fixture.saved = ["f": .stamp(7, .regular), "gone": .stamp(8, .regular)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "f", reason: .inodeChanged),
            WorkspacePublishRejection(relative: "gone", reason: .inodeChanged),
        ]))
    }

    @Test(arguments: [false, nil] as [Bool?])
    func removedDirectoryWithForeignNamesIsRefused(owned: Bool?) {
        var fixture = PlannerFixture(volume: [:], snapshot: ["d": .stamp(5, .directory)])
        fixture.saved = ["d": .stamp(5, .directory)]
        fixture.ownedSubtrees = ["d": owned]
        let reason: WorkspacePublishRejection.Reason = owned == nil ? .unreadable : .unexpectedNameInRemovedDirectory
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "d", reason: reason),
        ]))
    }

    // MARK: AC-B01: case handling

    @Test func caseOnlyRenameRespellsTheSnapshotAndItsSubtree() {
        var fixture = PlannerFixture(
            volume: ["utils": .directory(ino: 1), "utils/a.swift": .file(ino: 2)],
            snapshot: ["Utils": .stamp(5, .directory), "Utils/a.swift": .stamp(6, .regular)]
        )
        fixture.saved = ["utils": .stamp(5, .directory), "utils/a.swift": .stamp(6, .regular)]
        let result = fixture.plan(fixture.trees())
        #expect(result.plan == .planned([
            .renameCase(from: "Utils", to: "utils"),
            .updateFile("utils/a.swift", 0o644),
            .setDirectoryMode("utils", 0o755),
        ]))
        #expect(result.stamps == ["utils": .stamp(5, .directory), "utils/a.swift": .stamp(6, .regular)])
    }

    /// `b` is new on the volume but its saved lookup reaches `a`'s captured
    /// inode under a spelling that is not a case variant. `a` is gone from
    /// the volume and its saved inode is untouched, so on its own it would
    /// be retired. Retiring it would unlink the inode `b` now names.
    @Test func removedNameAnotherSpellingClaimsIsNotRetired() {
        var fixture = PlannerFixture(volume: ["b": .file(ino: 1)], snapshot: ["a": .stamp(5, .regular)])
        fixture.saved = ["a": .stamp(5, .regular), "b": .stamp(5, .regular)]
        #expect(fixture.plan(fixture.trees()).plan == .rejected([
            WorkspacePublishRejection(relative: "a", reason: .inodeChanged),
            WorkspacePublishRejection(relative: "b", reason: .inodeChanged),
        ]))
    }

    // MARK: AC-B01: symlinks

    @Test(arguments: ["same", "other"])
    func unchangedSymlinkIsSkippedAndARetargetIsReplaced(savedTarget: String) {
        var fixture = PlannerFixture(volume: ["l": .symlink(ino: 1)], snapshot: ["l": .stamp(5, .symlink)])
        fixture.volumeLinks = ["l": "same"]
        fixture.saved = ["l": .stamp(5, .symlink)]
        fixture.savedLinks = ["l": savedTarget]
        let expected: [PublishStep] = savedTarget == "same" ? [] : [.replaceSymlink("l", target: "same")]
        #expect(fixture.plan(fixture.trees()).plan == .planned(expected))
    }

    // MARK: AC-B01: clock stops

    /// Every `shouldStop` the mixed plan asks stops it there, with no fact
    /// asked afterwards.
    @Test func everyShouldStopPointStopsThePlan() {
        let fixture = PlannerFixture.mixed()
        let full = fixture.trees()
        _ = fixture.plan(full)
        let points = full.calls.filter { $0 == .shouldStop }.count
        #expect(points == 18)
        for point in 0..<points {
            let trees = fixture.trees()
            trees.stopAtCheck = point
            #expect(fixture.plan(trees).plan == .stopped, "stop point \(point)")
            #expect(trees.calls.last == .shouldStop, "stop point \(point)")
            #expect(trees.calls.filter { $0 == .shouldStop }.count == point + 1, "stop point \(point)")
        }
    }

    @Test func unansweredCaseQueryStopsBeforeRenames() {
        var fixture = PlannerFixture.mixed()
        fixture.foldsCase = nil
        let trees = fixture.trees()
        let result = fixture.plan(trees)
        #expect(result.plan == .stopped)
        #expect(result.stamps == fixture.snapshot)
        #expect(trees.calls.last == .savedFoldsCase)
    }

    @Test func unreadableRemovedSubtreeStopsWhenTheClockHasRunOut() {
        var fixture = PlannerFixture(volume: [:], snapshot: ["d": .stamp(5, .directory)])
        fixture.saved = ["d": .stamp(5, .directory)]
        fixture.ownedSubtrees = ["d": nil]
        let trees = fixture.trees()
        // Check 0 is the removed-name loop; check 1 follows the nil subtree.
        trees.stopAtCheck = 1
        #expect(fixture.plan(trees).plan == .stopped)
        #expect(trees.calls.suffix(2) == [.removedSubtreeOwned("d", ["d"]), .shouldStop])
    }
}

// MARK: - Fixture

private extension WorkspaceInodeStamp {
    static func stamp(_ inode: UInt64, _ kind: Kind, links: UInt64 = 1) -> WorkspaceInodeStamp {
        WorkspaceInodeStamp(device: 1, inode: inode, linkCount: links, kind: kind)
    }
}

private extension TreeEntry {
    /// Volume entries live on another device; the planner reads only kind and mode.
    static func file(ino: UInt64, mode: mode_t = 0o644) -> TreeEntry {
        TreeEntry(stamp: WorkspaceInodeStamp(device: 2, inode: ino, linkCount: 1, kind: .regular), mode: mode, bytes: 0)
    }

    static func directory(ino: UInt64, mode: mode_t = 0o755) -> TreeEntry {
        TreeEntry(stamp: WorkspaceInodeStamp(device: 2, inode: ino, linkCount: 2, kind: .directory), mode: mode, bytes: 0)
    }

    static func symlink(ino: UInt64) -> TreeEntry {
        TreeEntry(stamp: WorkspaceInodeStamp(device: 2, inode: ino, linkCount: 1, kind: .symlink), mode: 0o755, bytes: 0)
    }
}

private struct PlannerFixture {
    var volume: [String: TreeEntry]
    var snapshot: [String: WorkspaceInodeStamp]
    var special: [String] = []
    var volumeLinks: [String: String] = [:]
    var saved: [String: WorkspaceInodeStamp] = [:]
    var savedLinks: [String: String] = [:]
    var foldsCase: Bool? = true
    var ownedSubtrees: [String: Bool?] = [:]

    func trees() -> FakeTrees {
        let trees = FakeTrees()
        trees.volumeLinks = volumeLinks
        trees.saved = saved
        trees.savedLinks = savedLinks
        trees.foldsCase = foldsCase
        trees.ownedSubtrees = ownedSubtrees
        return trees
    }

    func plan(_ trees: FakeTrees) -> PublishPlanResult {
        WorkspacePublishPlanner.plan(volumeEntries: volume, special: special, snapshot: snapshot, facts: trees.facts)
    }

    static func mixed() -> PlannerFixture {
        var fixture = PlannerFixture(
            volume: [
                "README.md": .file(ino: 20),
                "link": .symlink(ino: 21),
                "src": .directory(ino: 22),
                "src/a.swift": .file(ino: 23, mode: 0o600),
                "src/gen": .directory(ino: 24, mode: 0o700),
                "src/new-link": .symlink(ino: 25),
                "src/new.swift": .file(ino: 26),
            ],
            snapshot: [
                "Readme.md": .stamp(10, .regular),
                "link": .stamp(11, .symlink),
                "src": .stamp(12, .directory),
                "src/a.swift": .stamp(13, .regular),
                "old": .stamp(14, .directory),
                "old/x.txt": .stamp(15, .regular),
            ]
        )
        fixture.volumeLinks = ["link": "src/a.swift", "src/new-link": "a.swift"]
        // The saved tree folds case, so `README.md` reaches `Readme.md`'s inode.
        fixture.saved = [
            "README.md": .stamp(10, .regular),
            "link": .stamp(11, .symlink),
            "src": .stamp(12, .directory),
            "src/a.swift": .stamp(13, .regular),
            "old": .stamp(14, .directory),
            "old/x.txt": .stamp(15, .regular),
        ]
        fixture.savedLinks = ["link": "src/a.swift"]
        return fixture
    }
}

/// Answers the planner from dictionaries and records every question.
private final class FakeTrees {
    enum Call: Equatable {
        case shouldStop
        case volumeLink(String)
        case savedStamp(String)
        case savedLink(String)
        case savedFoldsCase
        case removedSubtreeOwned(String, Set<String>)
        case publishStampsChanged([String: WorkspaceInodeStamp])
    }

    var calls: [Call] = []
    var volumeLinks: [String: String] = [:]
    var saved: [String: WorkspaceInodeStamp] = [:]
    var savedLinks: [String: String] = [:]
    var foldsCase: Bool? = true
    /// Missing keys are owned; a nil value is an unreadable subtree.
    var ownedSubtrees: [String: Bool?] = [:]
    /// The zero-based `shouldStop` call that answers true. Nil never stops.
    var stopAtCheck: Int?
    /// Set when `savedStamp` was handed stamps other than the last ones
    /// published, which the live boundary's walk would not have seen.
    var savedStampSawStaleStamps = false
    private var checks = 0
    private var published: [String: WorkspaceInodeStamp]?

    var facts: PublishFacts {
        PublishFacts(
            volumeLink: { relative in
                self.calls.append(.volumeLink(relative))
                return self.volumeLinks[relative]
            },
            savedStamp: { relative, stamps in
                self.calls.append(.savedStamp(relative))
                if stamps != self.published { self.savedStampSawStaleStamps = true }
                return self.saved[relative]
            },
            savedLink: { relative in
                self.calls.append(.savedLink(relative))
                return self.savedLinks[relative]
            },
            savedFoldsCase: {
                self.calls.append(.savedFoldsCase)
                return self.foldsCase
            },
            removedSubtreeOwned: { relative, removed in
                self.calls.append(.removedSubtreeOwned(relative, removed))
                guard let owned = self.ownedSubtrees[relative] else { return true }
                return owned
            },
            shouldStop: {
                self.calls.append(.shouldStop)
                defer { self.checks += 1 }
                return self.checks == self.stopAtCheck
            },
            publishStampsChanged: { stamps in
                self.calls.append(.publishStampsChanged(stamps))
                self.published = stamps
            }
        )
    }
}
#endif
