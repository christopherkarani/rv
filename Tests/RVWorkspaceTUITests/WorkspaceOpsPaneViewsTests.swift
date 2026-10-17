import Foundation
import Testing
import RVHistory
@testable import RVWorkspaceTUI

private func viewsEvent(
    seconds: Int,
    kind: AuditEventKind = .runtimeSession,
    decision: AuditDecision = .info,
    subject: String = "subject",
    detail: [String: String] = [:]
) -> AuditEvent {
    AuditEvent(
        time: Date(timeIntervalSince1970: TimeInterval(seconds)),
        kind: kind,
        decision: decision,
        subject: subject,
        reason: nil,
        workspace: nil,
        runtime: nil,
        agent: nil,
        source: "audit.jsonl",
        detail: detail
    )
}

/// Seeded ops list: `count` runtime events one second apart, tail pinned.
private func viewsSeededOps(count: Int = 5) -> OpsPaneState {
    var ops = OpsPaneState.initial()
    let events = (0..<count).map { viewsEvent(seconds: $0, subject: "event-\($0)") }
    ops.seed(events: events, cursor: AuditCursor())
    return ops
}

private func viewsPane(userTitle: String? = nil, content: PaneContent = .ops) -> WorkspacePane {
    WorkspacePane(id: PaneID(), userTitle: userTitle, content: content)
}

@Suite struct WorkspaceOpsPaneViewsTextTests {
    @Test func titleFallsBackToOpsAndSanitizesUserTitle() {
        #expect(WorkspaceOpsPaneText.title(viewsPane()) == "ops")
        #expect(WorkspaceOpsPaneText.title(viewsPane(userTitle: "audit tail")) == "audit tail")
        #expect(WorkspaceOpsPaneText.title(viewsPane(userTitle: "a\u{1b}b\u{202E}c")) == "abc")
        #expect(WorkspaceOpsPaneText.title(viewsPane(userTitle: "\u{07}")) == "ops")
    }

    @Test func titleStatusReflectsLoadAndFollow() {
        #expect(WorkspaceOpsPaneText.titleStatus(nil) == "loading")
        #expect(WorkspaceOpsPaneText.titleStatus(.initial()) == "loading")
        #expect(WorkspaceOpsPaneText.titleStatus(viewsSeededOps()) == "follow")
        var paused = viewsSeededOps()
        paused.moveCursor(by: -1)
        #expect(WorkspaceOpsPaneText.titleStatus(paused) == "paused")
    }

    @Test func contentLaysOutFilterBarRowsAndStatusRow() {
        let content = WorkspaceOpsPaneText.content(ops: viewsSeededOps(), height: 10)
        #expect(content.filterBar == "filter: all · 5 events")
        #expect(content.rows.count == 5)
        #expect(content.statusRow
            == "5/5 · j/k move · f follow · / filter · Enter detail · y yank")
    }

    @Test func rowsAreCompactClockKindDecisionSubjectLines() {
        let content = WorkspaceOpsPaneText.content(ops: viewsSeededOps(count: 3), height: 10)
        #expect(content.rows.map(\.text) == [
            "00:00:00 runtime.session info event-0",
            "00:00:01 runtime.session info event-1",
            "00:00:02 runtime.session info event-2",
        ])
    }

    @Test func rowsIncludeSortedDetailPairs() {
        var ops = OpsPaneState.initial()
        ops.seed(
            events: [viewsEvent(seconds: 1, subject: "s", detail: ["host": "h", "backend": "b"])],
            cursor: AuditCursor()
        )
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 5)
        #expect(content.rows.map(\.text) == ["00:00:01 runtime.session info s [backend=b host=h]"])
    }

    @Test func cursorRowIsFlaggedAtTail() {
        let content = WorkspaceOpsPaneText.content(ops: viewsSeededOps(), height: 10)
        #expect(content.rows.map(\.cursor) == [false, false, false, false, true])
    }

    @Test func windowKeepsCursorVisibleWhenAreaIsShorterThanStateViewport() {
        // The stored offset belongs to the full content height; the rendered
        // rows area is two lines shorter (filter bar + status row).
        var ops = viewsSeededOps(count: 10)
        ops.scrollOffset = 0
        #expect(ops.cursorIndex == 9)
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 3)
        #expect(content.filterBar != nil)
        #expect(content.statusRow != nil)
        #expect(content.rows.map(\.text) == ["00:00:09 runtime.session info event-9"])
        #expect(content.rows.map(\.cursor) == [true])
    }

    @Test func windowHonorsScrollOffsetWhenCursorIsVisible() {
        var ops = viewsSeededOps(count: 10)
        ops.scrollOffset = 5
        ops.cursorIndex = 5
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 5)
        #expect(content.rows.map(\.text) == [
            "00:00:05 runtime.session info event-5",
            "00:00:06 runtime.session info event-6",
            "00:00:07 runtime.session info event-7",
        ])
        #expect(content.rows.map(\.cursor) == [true, false, false])
    }

    @Test func shortHeightsDegradeFilterBarThenStatusRow() {
        let ops = viewsSeededOps()
        let two = WorkspaceOpsPaneText.content(ops: ops, height: 2)
        #expect(two.filterBar == "filter: all · 5 events")
        #expect(two.statusRow == nil)
        #expect(two.rows.count == 1)
        #expect(two.rows[0].cursor)
        let one = WorkspaceOpsPaneText.content(ops: ops, height: 1)
        #expect(one.filterBar == nil)
        #expect(one.statusRow == nil)
        #expect(one.rows.count == 1)
        let zero = WorkspaceOpsPaneText.content(ops: ops, height: 0)
        #expect(zero == WorkspaceOpsPaneText.Content(filterBar: nil, rows: [], statusRow: nil))
    }

    @Test func deniedRowsAreFlagged() {
        var ops = OpsPaneState.initial()
        ops.seed(
            events: [
                viewsEvent(seconds: 0, decision: .info, subject: "ok"),
                viewsEvent(seconds: 1, kind: .commandDenied, decision: .denied, subject: "rm"),
            ],
            cursor: AuditCursor()
        )
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 10)
        #expect(content.rows.map(\.denied) == [false, true])
    }

    @Test func visualRangeIsFlaggedBetweenAnchorAndCursor() {
        var ops = viewsSeededOps(count: 5)
        ops.moveCursor(by: -4)
        ops.toggleAnchor()
        ops.moveCursor(by: 2)
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 10)
        #expect(content.rows.map(\.inRange) == [true, true, true, false, false])
        #expect(content.rows.map(\.cursor) == [false, false, true, false, false])
    }

    @Test func unloadedPaneShowsLoadingPlaceholders() {
        let content = WorkspaceOpsPaneText.content(ops: .initial(), height: 5)
        #expect(content.filterBar == "filter: all · loading…")
        #expect(content.rows.map(\.text) == ["loading audit history…"])
        #expect(content.statusRow?.hasPrefix("0/0 · ") == true)
    }

    @Test func nilOpsRendersAsUnloaded() {
        #expect(WorkspaceOpsPaneText.content(ops: nil, height: 5)
            == WorkspaceOpsPaneText.content(ops: .initial(), height: 5))
    }

    @Test func emptyStatesNameTheFilter() {
        var ops = OpsPaneState.initial()
        ops.seed(events: [], cursor: AuditCursor())
        let all = WorkspaceOpsPaneText.content(ops: ops, height: 5)
        #expect(all.rows.map(\.text) == ["no audit events"])
        #expect(all.filterBar == "filter: all · 0 events")
        #expect(all.statusRow?.hasPrefix("0/0 · ") == true)
        ops.cycleFilter()
        #expect(ops.filter == .denied)
        let denied = WorkspaceOpsPaneText.content(ops: ops, height: 5)
        #expect(denied.rows.map(\.text) == ["no events match filter denied"])
    }

    @Test func filterBarShowsActiveFilterAndCount() {
        var ops = viewsSeededOps(count: 4)
        ops.events[0] = viewsEvent(seconds: 0, decision: .denied, subject: "event-0")
        ops.cycleFilter()
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 10)
        #expect(content.filterBar == "filter: denied · 1 events")
        #expect(content.rows.map(\.text) == ["00:00:00 runtime.session denied event-0"])
    }

    @Test func statusRowNamesVisualAndDetailModes() {
        var visual = viewsSeededOps()
        visual.toggleAnchor()
        #expect(WorkspaceOpsPaneText.content(ops: visual, height: 5).statusRow
            == "5/5 · VISUAL · y yank · v clear")
        var detail = viewsSeededOps()
        detail.openDetail()
        #expect(WorkspaceOpsPaneText.content(ops: detail, height: 5).statusRow
            == "Detail · Enter/Esc close")
    }

    @Test func sanitizeStripsControlsAndBidiFromRows() {
        #expect(WorkspaceOpsPaneText.sanitize("a\u{1b}b\u{202E}c\u{2066}d\u{07}e") == "abcde")
        #expect(WorkspaceOpsPaneText.sanitize("line\nbreak") == "line break")
        #expect(WorkspaceOpsPaneText.sanitize("a\rb\tc") == "ab c")
        #expect(WorkspaceOpsPaneText.sanitize("ok-其它-🎉") == "ok-其它-🎉")
    }

    @Test func sanitizePreservesNewlinesForBlocks() {
        #expect(WorkspaceOpsPaneText.sanitize("a\nb", preserveNewlines: true) == "a\nb")
        #expect(WorkspaceOpsPaneText.sanitize("a\rb\u{07}c", preserveNewlines: true) == "abc")
        #expect(WorkspaceOpsPaneText.sanitize("a\u{202B}b", preserveNewlines: true) == "ab")
    }

    @Test func rowsSanitizeAuditSubjects() {
        var ops = OpsPaneState.initial()
        ops.seed(
            events: [viewsEvent(seconds: 0, subject: "x\u{1b}[2Jy\nz")],
            cursor: AuditCursor()
        )
        let content = WorkspaceOpsPaneText.content(ops: ops, height: 5)
        #expect(content.rows.map(\.text) == ["00:00:00 runtime.session info x[2Jy z"])
        #expect(content.rows[0].text.contains("\n") == false)
    }
}

@Suite struct WorkspaceOpsDetailOverlayTests {
    @Test func overlayIsNilUnlessAnOpsDetailIsOpen() {
        let ops = viewsSeededOps()
        #expect(WorkspaceOpsPaneText.detailOverlay(pane: viewsPane(), ops: ops) == nil)
        #expect(WorkspaceOpsPaneText.detailOverlay(pane: viewsPane(), ops: nil) == nil)
        #expect(WorkspaceOpsPaneText.detailOverlay(
            pane: viewsPane(content: .terminal), ops: ops
        ) == nil)
        var detail = viewsSeededOps()
        detail.openDetail()
        #expect(WorkspaceOpsPaneText.detailOverlay(
            pane: viewsPane(content: .terminal), ops: detail
        ) == nil)
    }

    @Test func overlayShowsHeaderPlusDetailBody() {
        var ops = OpsPaneState.initial()
        ops.seed(
            events: [viewsEvent(
                seconds: 61,
                kind: .mcpCall,
                decision: .allowed,
                subject: "tool",
                detail: ["requestID": "r1"]
            )],
            cursor: AuditCursor()
        )
        ops.openDetail()
        #expect(WorkspaceOpsPaneText.detailOverlay(pane: viewsPane(), ops: ops) == """
            DETAIL · Enter/Esc close
            time: 1970-01-01T00:01:01Z
            kind: mcp.call
            decision: allowed
            subject: tool
            source: audit.jsonl
            Detail:
              requestID=r1
            """)
    }

    @Test func overlayShowsTheOpenRowNotTheCursor() {
        var ops = viewsSeededOps(count: 3)
        ops.moveCursor(by: -2)
        ops.openDetail()
        ops.moveCursor(by: 1)
        let overlay = try! #require(WorkspaceOpsPaneText.detailOverlay(pane: viewsPane(), ops: ops))
        #expect(overlay.contains("subject: event-0"))
        #expect(overlay.contains("subject: event-1") == false)
    }

    @Test func overlaySanitizesControlBytes() {
        var ops = OpsPaneState.initial()
        ops.seed(events: [viewsEvent(seconds: 0, subject: "x\u{1b}y\u{202E}z")], cursor: AuditCursor())
        ops.openDetail()
        let overlay = try! #require(WorkspaceOpsPaneText.detailOverlay(pane: viewsPane(), ops: ops))
        #expect(overlay.contains("subject: xyz"))
        #expect(overlay.contains("\u{1b}") == false)
    }
}
