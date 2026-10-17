import Foundation
import RVHistory

/// What one pane shows. Geometry, tabs, focus, and zoom stay
/// content-agnostic: only the reducer's input routing and the render views
/// branch on this.
public enum PaneContent: String, Codable, Sendable {
    case terminal
    case ops
}

/// Which audit events one ops pane lists. Cycles in declaration order.
public enum OpsPaneFilter: String, Codable, Sendable, CaseIterable {
    case all
    case denied
    case admission
    case runtime
    case policy

    public func next() -> Self {
        let cases = Self.allCases
        guard let index = cases.firstIndex(of: self) else { return .all }
        return cases[(index + 1) % cases.count]
    }

    public var label: String {
        switch self {
        case .all: "all"
        case .denied: "denied"
        case .admission: "admission"
        case .runtime: "runtime"
        case .policy: "policy"
        }
    }

    public func admits(_ event: AuditEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .denied:
            return event.decision == .denied
        case .admission:
            return event.kind.matches("admission")
        case .runtime:
            return event.kind.matches("runtime")
                || event.kind.matches("workspace")
                || event.kind.matches("agent")
        case .policy:
            return event.kind.matches("mcp")
                || event.kind.matches("secret")
                || event.kind.matches("command")
        }
    }
}

/// How much of the filtered list one copy takes.
public enum OpsCopyMode: Equatable, Sendable {
    case line
    case viewport
    case range
}

/// Live audit tail for one ops pane: a bounded newest-first ring fed by
/// history-then-live (`AuditLedger.events` seed, `events(after:)` polls),
/// plus the list position the keys drive.
///
/// `events` stays oldest-first. `cursorIndex` and `scrollOffset` address the
/// filtered list; `selectionAnchor` pins one end of a visual range and
/// `detailIndex` names the open detail row, both in filtered coordinates.
public struct OpsPaneState: Equatable, Sendable {
    /// Newest events retained; older ones drop on seed and poll.
    public static let maximumEvents = 2000
    /// Seed size for `loadOpsHistory`.
    public static let historySeedLimit = 500
    /// Per-poll read size for `pollOps`.
    public static let pollLimit = 200
    /// Minimum age of a poll before the tick issues another.
    public static let pollInterval: TimeInterval = 0.5
    /// List height before the first pane size note arrives.
    public static let defaultViewportRows = 24

    public var events: [AuditEvent]
    public var cursor: AuditCursor
    public var filter: OpsPaneFilter
    public var follow: Bool
    public var scrollOffset: Int
    public var cursorIndex: Int
    public var selectionAnchor: Int?
    public var detailIndex: Int?
    public var viewportRows: Int
    public var loaded: Bool
    public var lastPollAt: Date?

    public init(
        events: [AuditEvent] = [],
        cursor: AuditCursor = AuditCursor(),
        filter: OpsPaneFilter = .all,
        follow: Bool = true,
        scrollOffset: Int = 0,
        cursorIndex: Int = 0,
        selectionAnchor: Int? = nil,
        detailIndex: Int? = nil,
        viewportRows: Int = Self.defaultViewportRows,
        loaded: Bool = false,
        lastPollAt: Date? = nil
    ) {
        self.events = events
        self.cursor = cursor
        self.filter = filter
        self.follow = follow
        self.scrollOffset = scrollOffset
        self.cursorIndex = cursorIndex
        self.selectionAnchor = selectionAnchor
        self.detailIndex = detailIndex
        self.viewportRows = viewportRows
        self.loaded = loaded
        self.lastPollAt = lastPollAt
    }

    /// Fresh pane: unloaded, following, pinned at the (empty) tail.
    public static func initial() -> Self { Self() }

    /// Admitted events, oldest first.
    public var filtered: [AuditEvent] {
        filter == .all ? events : events.filter(filter.admits)
    }

    /// Lands the history seed: newest ring kept, cursor stored, tail pinned
    /// while following, clamped otherwise. Resets transient selection.
    public mutating func seed(events: [AuditEvent], cursor: AuditCursor) {
        self.events = Self.ring(events)
        self.cursor = cursor
        loaded = true
        selectionAnchor = nil
        detailIndex = nil
        if follow { tail() } else { clampPositions() }
    }

    /// Appends one poll: exact duplicates of retained events drop (the seed
    /// overlaps the first poll by design, so history-then-live never loses
    /// a line), the ring stays newest-first capped, and the cursor advances.
    public mutating func appendPolled(_ polled: [AuditEvent], cursor: AuditCursor) {
        if polled.isEmpty == false {
            let retained = Set(events.map(DedupKey.init))
            let fresh = polled.filter { retained.contains(DedupKey($0)) == false }
            if fresh.isEmpty == false {
                events = Self.ring(events + fresh)
            }
        }
        self.cursor = cursor
        if follow { tail() } else { clampPositions() }
    }

    /// Moves the selection, pausing follow and keeping the row on screen.
    /// A set anchor stays: the move extends the visual range.
    public mutating func moveCursor(by delta: Int) {
        guard delta != 0 else { return }
        follow = false
        cursorIndex = clampedIndex(cursorIndex + delta)
        keepCursorVisible()
    }

    /// Scrolls the list without moving the selection, pausing follow.
    public mutating func scroll(by delta: Int) {
        guard delta != 0 else { return }
        follow = false
        scrollOffset = clampedIndex(scrollOffset + delta)
    }

    /// Pins the selection and the viewport to the newest row.
    public mutating func tail() {
        cursorIndex = clampedIndex(filtered.count - 1)
        scrollOffset = max(0, filtered.count - max(1, viewportRows))
    }

    public mutating func cycleFilter() {
        filter = filter.next()
        selectionAnchor = nil
        detailIndex = nil
        if follow { tail() } else { clampPositions() }
    }

    public mutating func setFollow(_ value: Bool) {
        follow = value
        if follow { tail() }
    }

    public mutating func toggleFollow() {
        setFollow(follow == false)
    }

    /// Opens the detail row at the selection. Empty lists stay closed.
    public mutating func openDetail() {
        detailIndex = filtered.indices.contains(cursorIndex) ? cursorIndex : nil
    }

    public mutating func closeDetail() {
        detailIndex = nil
    }

    /// Pins or clears the visual anchor at the selection.
    public mutating func toggleAnchor() {
        selectionAnchor = selectionAnchor == nil ? cursorIndex : nil
    }

    /// Plain-text rows for one copy. Nil when there is nothing to copy.
    /// Rows are sanitized like the display, so a yanked "line" is one line
    /// even when the audit subject carries newlines or control bytes. The
    /// caller clears the anchor after a range copy.
    public func copyText(_ mode: OpsCopyMode) -> String? {
        let rows = filtered
        switch mode {
        case .line:
            guard rows.indices.contains(cursorIndex) else { return nil }
            return OpsPaneFormat.sanitize(OpsPaneFormat.row(rows[cursorIndex]))
        case .viewport:
            // The stored offset can sit past the window start (a page scroll
            // clamps to the last row, not the last page), so the start is
            // re-derived exactly like the rendered window.
            let span = max(1, viewportRows)
            let start = min(max(0, scrollOffset), max(0, rows.count - span))
            let end = min(rows.count, start + span)
            guard start < end else { return nil }
            return rows[start..<end]
                .map { OpsPaneFormat.sanitize(OpsPaneFormat.row($0)) }
                .joined(separator: "\n")
        case .range:
            guard rows.isEmpty == false else { return nil }
            let anchor = selectionAnchor ?? cursorIndex
            let range = min(anchor, cursorIndex)...max(anchor, cursorIndex)
            let clamped = range.clamped(to: 0...(rows.count - 1))
            return rows[clamped]
                .map { OpsPaneFormat.sanitize(OpsPaneFormat.row($0)) }
                .joined(separator: "\n")
        }
    }

    // MARK: - Private

    /// Oldest-first, newest capped.
    private static func ring(_ events: [AuditEvent]) -> [AuditEvent] {
        let sorted = events.sorted { $0.time < $1.time }
        return Array(sorted.suffix(maximumEvents))
    }

    private func clampedIndex(_ value: Int) -> Int {
        min(max(0, filtered.count - 1), max(0, value))
    }

    private mutating func clampPositions() {
        cursorIndex = clampedIndex(cursorIndex)
        scrollOffset = clampedIndex(scrollOffset)
        if let detailIndex, filtered.indices.contains(detailIndex) == false {
            self.detailIndex = filtered.isEmpty ? nil : clampedIndex(detailIndex)
        }
        if let selectionAnchor {
            self.selectionAnchor = filtered.isEmpty ? nil : clampedIndex(selectionAnchor)
        }
    }

    private mutating func keepCursorVisible() {
        let height = max(1, viewportRows)
        if cursorIndex < scrollOffset {
            scrollOffset = cursorIndex
        } else if cursorIndex >= scrollOffset + height {
            scrollOffset = cursorIndex - height + 1
        }
    }
}

/// Full identity minus the chain links: two ledger lines equal on every
/// field here are indistinguishable, so either copy stands for both.
private struct DedupKey: Hashable {
    var time: Date
    var kind: String
    var decision: AuditDecision
    var subject: String
    var reason: String?
    var workspace: String?
    var runtime: String?
    var agent: String?
    var source: String
    var detail: [String: String]

    init(_ event: AuditEvent) {
        time = event.time
        kind = event.kind.rawValue
        decision = event.decision
        subject = event.subject
        reason = event.reason
        workspace = event.workspace
        runtime = event.runtime
        agent = event.agent
        source = event.source
        detail = event.detail
    }
}

/// Plain-text rendering for ops rows, copies, and the detail view.
/// Clocks are UTC so shared panes and tests read one time.
public enum OpsPaneFormat {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    /// `HH:MM:SS kind decision subject [k=v ...]`; no bracket when empty.
    public static func row(_ event: AuditEvent) -> String {
        var line = "\(clock(event.time)) \(event.kind.rawValue) \(event.decision.rawValue) \(event.subject)"
        if event.detail.isEmpty == false {
            let pairs = event.detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            line += " [\(pairs.joined(separator: " "))]"
        }
        return line
    }

    /// One field per line; absent optionals and empty detail stay out.
    public static func detail(_ event: AuditEvent) -> String {
        var lines = [
            "time: \(iso(event.time))",
            "kind: \(event.kind.rawValue)",
            "decision: \(event.decision.rawValue)",
            "subject: \(event.subject)",
        ]
        if let reason = event.reason { lines.append("reason: \(reason)") }
        if let workspace = event.workspace { lines.append("workspace: \(workspace)") }
        if let runtime = event.runtime { lines.append("runtime: \(runtime)") }
        if let agent = event.agent { lines.append("agent: \(agent)") }
        lines.append("source: \(event.source)")
        if event.detail.isEmpty == false {
            lines.append("Detail:")
            for pair in event.detail.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(pair.key)=\(pair.value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Drops the same bytes `WorkspacePaneChrome.safe` drops (control
    /// characters and bidi overrides) without truncating or trimming, so
    /// audit subjects cannot inject layout or escape sequences. Single-line
    /// callers get newlines and tabs as spaces and carriage returns dropped;
    /// block callers keep newlines and drop carriage returns.
    public static func sanitize(_ raw: String, preserveNewlines: Bool = false) -> String {
        let space = UnicodeScalar(" ")
        let scalars = raw.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            if scalar == UnicodeScalar("\n") { return preserveNewlines ? scalar : space }
            if scalar == UnicodeScalar("\r") { return nil }
            if scalar == UnicodeScalar("\t") { return space }
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) { return nil }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func clock(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02d:%02d:%02d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    public static func iso(_ date: Date) -> String {
        let parts = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
