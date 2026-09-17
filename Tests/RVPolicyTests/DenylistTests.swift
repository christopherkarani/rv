import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct DenylistTests {
    @Test func emptyText_isEmptySnapshot() throws {
        #expect(try DenylistTOML.parse("") == [])
        #expect(try DenylistTOML.parse("   \n") == [])
        #expect(DenylistTOML.render([]) == "")
        #expect(DenylistSnapshot.empty.entries.isEmpty)
        #expect(DenylistSnapshot.empty.matches("git reset --hard") == false)
    }

    @Test func parseAndMatch_exactCommand() throws {
        let entries = try DenylistTOML.parse(
            """
            # dashboard always-block
            [[block]]
            exact_command = "rm -rf ./build"
            reason = "never this matching view"
            added_at = "2026-01-08T12:00:00Z"
            """
        )
        #expect(entries.count == 1)
        #expect(entries[0].matchingView == MatchingView("rm -rf ./build"))
        #expect(entries[0].reason == "never this matching view")
        let snap = DenylistSnapshot(entries: entries)
        #expect(snap.matches("rm -rf ./build"))
        #expect(snap.matches("git status") == false)
    }

    @Test func missingAddedAt_isEpoch() throws {
        let entries = try DenylistTOML.parse(
            """
            [[block]]
            exact_command = "git reset --hard"
            reason = "pinned"
            """
        )
        #expect(entries[0].addedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func commentsBlankLinesAndEscapes_roundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = [
            DenylistEntry(
                matchingView: MatchingView(#"echo "quoted" \ path"#),
                reason: #"say "no" and \ keep"# ,
                addedAt: now
            ),
        ]
        let rendered = DenylistTOML.render(original)
        #expect(rendered.hasSuffix("\n"))
        let parsed = try DenylistTOML.parse(rendered)
        #expect(parsed[0].matchingView == original[0].matchingView)
        #expect(parsed[0].reason == original[0].reason)
        #expect(abs(parsed[0].addedAt.timeIntervalSince1970 - now.timeIntervalSince1970) < 1)
    }

    @Test func fractionalSeconds_parse() throws {
        let entries = try DenylistTOML.parse(
            """
            [[block]]
            exact_command = "mkfs.ext4 /dev/sda"
            reason = "disk"
            added_at = "2026-01-08T12:00:00.250Z"
            """
        )
        #expect(entries[0].matchingView.rawValue == "mkfs.ext4 /dev/sda")
        #expect(entries[0].addedAt.timeIntervalSince1970 > 0)
    }

    @Test func twoBlocks_keepOrder() throws {
        let entries = try DenylistTOML.parse(
            """
            [[block]]
            exact_command = "first"
            reason = "one"

            [[block]]
            exact_command = "second"
            reason = "two"
            """
        )
        #expect(entries.map(\.matchingView.rawValue) == ["first", "second"])
    }

    @Test func missingReason() {
        #expect(throws: DenylistParseError.missingReason) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command = "git reset --hard"
                """
            )
        }
    }

    @Test func emptyReason() {
        #expect(throws: DenylistParseError.emptyReason) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command = "git reset --hard"
                reason = "   "
                """
            )
        }
    }

    @Test func missingAndEmptyCommand() {
        #expect(throws: DenylistParseError.missingCommand) {
            try DenylistTOML.parse(
                """
                [[block]]
                reason = "no command"
                """
            )
        }
        #expect(throws: DenylistParseError.missingCommand) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command = "  "
                reason = "blank"
                """
            )
        }
    }

    @Test func invalidDate() {
        #expect(throws: DenylistParseError.invalidDate("not-a-date")) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command = "git reset --hard"
                reason = "bad date"
                added_at = "not-a-date"
                """
            )
        }
    }

    @Test func unknownKeyAndMissingEquals_areInvalidTOML() {
        #expect(throws: DenylistParseError.invalidTOML) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command = "git reset --hard"
                reason = "ok"
                extra = "no"
                """
            )
        }
        #expect(throws: DenylistParseError.invalidTOML) {
            try DenylistTOML.parse(
                """
                [[block]]
                exact_command "git reset --hard"
                reason = "ok"
                """
            )
        }
        #expect(throws: DenylistParseError.invalidTOML) {
            try DenylistTOML.parse("not a table")
        }
    }

    @Test func allowlistHonor_isSuppressedByBlockedMatchingView() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let view = MatchingView("rm -rf ./build")
        let snap = AllowlistSnapshot(
            entries: [
                AllowlistEntry(
                    selector: .exactCommand(view),
                    reason: "CI cleanup",
                    addedAt: now
                ),
            ],
            blocked: DenylistSnapshot(
                entries: [
                    DenylistEntry(matchingView: view, reason: "always block", addedAt: now),
                ]
            )
        )
        #expect(snap.matches(ruleID: nil, matchingView: view, now: now) == false)
        #expect(snap.blocked.matches(view))
    }

    @Test func splitBlock_dropsLeadingCommentsWithoutHeader() {
        let blocks = splitBlock(
            """
            # preface
            leftover = "stray"

            [[block]]
            exact_command = "git status"
            reason = "ok"
            """,
            header: "[[block]]"
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("[[block]]"))
        #expect(blocks[0].contains("leftover") == false)
    }
}
