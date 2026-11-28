import Foundation
import RVIsolation
import Testing
@testable import RVCLI

/// `rv box tidy`'s words, against the v4 Contained frame.
@Suite("rv box tidy speaks the v4 words")
struct BoxTidyRenderTests {
    static let home = "/Users/chris"
    static let utc = TimeZone(identifier: "UTC")!
    static let nov19 = Date(timeIntervalSince1970: 1_795_046_400)  // 2026-11-19 UTC

    static func plan(kept: [BoxTidyBox] = [], moves: Int = 0, expired: Int = 0, hold: BoxTidyHold? = nil) -> BoxTidyPlan {
        BoxTidyPlan(
            kept: kept,
            moves: (0..<moves).map { .imageFile(path: "/tmp/rv-inode-\($0).sparseimage") },
            expired: (0..<expired).map { BoxTrashEntry(path: "/t/\($0)", trashedAt: .distantPast) },
            hold: hold)
    }

    static let app = BoxTidyBox(project: "/Users/chris/code/app", lastActive: nov19, state: .unfinished)

    @Test func theFrame() {
        let plan = Self.plan(kept: [Self.app], moves: 252)
        #expect(BoxTidyRender.summary(plan, home: Self.home, timeZone: Self.utc) == """
            ◆ rv 1 box never finished · 252 old images
              ◐ ~/code/app   may hold unsaved work · Nov 19 · cd ~/code/app && rv box

            """)
        #expect(BoxTidyRender.question(plan) == "  Move 252 to trash? The box with unsaved work stays. y/n ")
        #expect(BoxTidyRender.done(BoxTidyOutcome(moved: 252)) == "  ✓ Tidied · trash empties in 7 days\n")
    }

    @Test func openBoxesAreKeptButNotListed() {
        let open = BoxTidyBox(project: "/Users/chris/code/site", lastActive: Self.nov19, state: .open)
        let plan = Self.plan(kept: [open], moves: 1)
        #expect(BoxTidyRender.summary(plan, home: Self.home, timeZone: Self.utc) == "◆ rv 1 old image\n")
        #expect(BoxTidyRender.question(plan) == "  Move 1 to trash? y/n ")
    }

    @Test func severalBoxesStay() {
        let site = BoxTidyBox(project: "/srv/site", lastActive: Self.nov19, state: .unfinished)
        let plan = Self.plan(kept: [Self.app, site], moves: 3)
        #expect(BoxTidyRender.question(plan) == "  Move 3 to trash? Boxes with unsaved work stay. y/n ")
        #expect(BoxTidyRender.summary(plan, home: Self.home, timeZone: Self.utc).hasPrefix(
            "◆ rv 2 boxes never finished · 3 old images\n"))
    }

    @Test func nothingToTidy() {
        #expect(BoxTidyRender.summary(Self.plan(), home: Self.home) == "✓ Nothing to tidy.\n")
        // Only the expired trash: it is named, and emptying it waits for a yes.
        #expect(BoxTidyRender.summary(Self.plan(expired: 2), home: Self.home) == "◆ rv 2 in the trash past 7 days\n")
        #expect(BoxTidyRender.question(Self.plan(expired: 2)) == "  Empty 2 from the trash for good? y/n ")
        #expect(BoxTidyRender.question(Self.plan(moves: 3, expired: 2))
            == "  Move 3 to trash and empty 2 for good? y/n ")
        #expect(BoxTidyRender.done(BoxTidyOutcome(emptied: 2)) == "  ✓ Tidied · emptied 2 from the trash\n")
        #expect(BoxTidyRender.done(BoxTidyOutcome()) == "  Nothing moved.\n")
    }

    @Test func holdsSayWhyAndWhatNext() {
        #expect(BoxTidyRender.holdText(.boxBusy(project: "/Users/chris/code/app"), home: Self.home) == """
              ◐ Nothing moved: the box for ~/code/app is still starting.
              → run it again once that box is open: rv box tidy

            """)
        #expect(BoxTidyRender.holdText(.attachedUnknown, home: Self.home) == """
              ✕ Nothing moved: rv could not read which images are in use.
              → rv doctor

            """)
    }

    @Test func leftoversThatStayAreCounted() {
        #expect(BoxTidyRender.done(BoxTidyOutcome(moved: 3, stayed: 2)) == """
              ✓ Tidied · trash empties in 7 days
              ◐ 2 could not move: still in use or on another disk.
              → rv workspace leftovers

            """)
    }

    @Test func noTerminalNamesTheYesFlag() {
        #expect(BoxTidyRender.notAsked == "  → nothing changed; to tidy: rv box tidy --yes\n")
    }

    /// Something a box claimed after the yes is left alone, and said so.
    @Test func leftoversClaimedAfterTheYesAreCounted() {
        #expect(BoxTidyRender.done(BoxTidyOutcome(moved: 2), asked: 3) == """
              ✓ Tidied · trash empties in 7 days
              ◐ 1 left alone: in use since you were asked.

            """)
    }

    @Test func tidyIsATarget() {
        #expect(BoxPlan.target(["tidy"]) == .success(.tidy(yes: false)))
        #expect(BoxPlan.target(["tidy", "--yes"]) == .success(.tidy(yes: true)))
        #expect(BoxPlan.target(["tidy", "-y"]) == .success(.tidy(yes: true)))
        guard case .failure(let refusal) = BoxPlan.target(["tidy", "--all"]) else {
            Issue.record("tidy --all must be refused")
            return
        }
        #expect(refusal.text == "✕ rv box tidy has no --all option.\n  → rv box tidy\n")
        #expect(BoxPlan.checkFlags(linux: true, mac: false, profile: nil, target: .tidy(yes: false))?.text
            == "✕ rv box tidy takes no --linux, --mac or --profile.\n  → rv box tidy\n")
    }
}
