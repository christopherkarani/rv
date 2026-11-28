import Foundation
import RVTheme
import Testing
@testable import RVCLI
@testable import RVUndo

/// `rv undo`'s words: the v3 "Kept a copy first" frame.
@Suite("rv undo screen")
struct UndoCommandTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let at = Date(timeIntervalSince1970: 1_800_000_000 - 8 * 3600 + 14 * 3600 + 3 * 60)

    static func manifest(_ kind: UndoManifest.Kind, tally: UndoTally, notes: [String] = []) -> UndoManifest {
        UndoManifest(
            schema: 1, id: "20270115-140300-abcd", createdAt: at, host: "claude",
            command: "git reset --hard origin/main", reason: .unlocked, repoRoot: "/Users/chris/code/app", kind: kind,
            git: kind == .git ? .init(head: "9f2c1e0aaaa", stash: "abc") : nil,
            paths: [], tally: tally, notes: notes)
    }

    var screen: UndoScreen {
        var screen = UndoScreen(palette: colorOffPalette, home: "/Users/chris")
        screen.timeZone = Self.utc
        return screen
    }

    /// A git copy as the keeper writes it: files and the bytes handed to
    /// git, no line count (no diff runs in rvd).
    @Test("a kept reset reads as the frame")
    func gitSummary() {
        var tally = UndoTally()
        tally.files = 14
        tally.bytes = 86 * 1024
        tally.lines = nil
        #expect(screen.summary(Self.manifest(.git, tally: tally)) == [
            "",
            "  14:03  claude  git reset --hard origin/main   unlocked",
            "         ◆ rv kept a copy first: 14 files · 86 KB",
            "",
        ])
        #expect(screen.question(repository: "/Users/chris/code/app") == "  Restore into ~/code/app?  [y/N] ")
        #expect(screen.restored(.branch("rv/restore-1403"), store: UndoStore(root: URL(fileURLWithPath: "/s")),
                                manifest: Self.manifest(.git, tally: tally))
            == ["  ✓ Back, on branch rv/restore-1403. Nothing was overwritten."])
    }

    @Test("a skipped copy says why")
    func skipped() {
        let lines = screen.summary(Self.manifest(.skipped, tally: UndoTally(), notes: [UndoSkip.tooBig(bytes: 300 << 20).note]))
        #expect(lines[2] == "         ◆ rv kept no copy.")
        #expect(lines[3] == "         Too big to keep a copy (300 MB; the limit is 256 MB).")
    }

    @Test("files put back, and what was already there")
    func files() {
        let store = UndoStore(root: URL(fileURLWithPath: "/Users/chris/.config/rv/undo"))
        let manifest = Self.manifest(.files, tally: UndoTally())
        #expect(screen.restored(.files(restored: 3, leftInPlace: ["build"]), store: store, manifest: manifest) == [
            "  ✓ Back, 3 files. Nothing was overwritten.",
            "  Already there, so left alone: build.",
            "  Their copy is in ~/.config/rv/undo/20270115-140300-abcd/data.",
        ])
    }

    @Test("text from the manifest cannot drive the terminal: controls and bidi marks are dropped")
    func manifestTextIsPlain() {
        var manifest = Self.manifest(.skipped, tally: UndoTally(), notes: ["Too big\u{1B}[2J\u{9B}31m"])
        manifest.command = "rm -rf \u{202E}txt.exe\u{2066}\u{200B}\nbuild\r"
        manifest.host = "claude\u{07}"
        let lines = screen.summary(manifest)
        #expect(lines[1] == "  14:03  claude  rm -rf txt.exebuild   unlocked")
        #expect(lines[3] == "         Too big[2J31m")
        #expect(screen.list([manifest]) == ["  14:03  claude  rm -rf txt.exebuild   no copy   20270115-140300-abcd"])
        #expect(screen.restored(.files(restored: 1, leftInPlace: ["a\u{1B}]0;x\u{07}b"]), store: UndoStore(root: URL(fileURLWithPath: "/s")),
                                manifest: manifest)[1] == "  Already there, so left alone: a]0;xb.")
    }

    @Test("an agent without a terminal is sent to the person")
    func needsTerminal() {
        #expect(screen.needsTerminal() == ["  Restoring is the person's call, at a terminal.", "  → rv undo"])
        #expect(screen.none(repository: "/Users/chris/code/app")
            == ["  ◆ rv has no copies for ~/code/app from the last 7 days."])
    }
}
