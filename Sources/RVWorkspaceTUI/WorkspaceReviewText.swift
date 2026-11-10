import Foundation

/// Pure text for the review pane. No rendering, no I/O.
///
/// Every string that came from a store is untrusted: an agent can create
/// a path or a host label holding escape sequences meant to repaint the
/// pane (for example a fake "approved" line). `clean` strips control and
/// bidi scalars from each line before it reaches the terminal.
///
/// Nothing on the approve/deny path is cut silently. Egress detail lines
/// wrap at the pane width and are never shortened; list rows shorten only
/// with a visible `…` in the middle, keeping the host's registrable tail
/// and port. A pane too short for all of it shows `tooSmall` instead of a
/// clipped review.
enum WorkspaceReviewText {
    static let listRows = 8
    /// Block detail (explain output) shown; egress detail is never cut.
    static let detailRows = 14
    /// Width used when the caller does not know the pane size.
    static let defaultColumns = 160
    static let tooSmall = "terminal too small to review safely"

    static func lines(
        _ review: WorkspaceReviewState, mode: CommandMode, now: Date,
        columns: Int = defaultColumns, rows: Int? = nil
    ) -> [String] {
        let width = max(1, columns)
        let wrapped = wholeReview(review, mode: mode, now: now, width: width)
        guard let rows, fits(wrapped, rows: rows) == false else { return wrapped }
        var refusal = [tooSmall, "need \(wrapped.count) rows, have \(rows) · Esc close"]
        // A refused approve explains itself even while the review is hidden.
        if let notice = review.notice { refusal.append(noticeLine(notice)) }
        return Array(refusal.flatMap { wrap($0, width: width) }.prefix(max(0, rows)))
    }

    /// The one "too small" answer the render and the reducer share: true
    /// only when the pane has been measured and the whole review fits in
    /// it. Approve is refused whenever this is false; deny never needs it.
    static func showsWholeReview(_ review: WorkspaceReviewState, mode: CommandMode, now: Date) -> Bool {
        guard let size = review.paneSize else { return false }
        return fits(wholeReview(review, mode: mode, now: now, width: max(1, size.columns)), rows: size.rows)
    }

    private static func fits(_ wrapped: [String], rows: Int) -> Bool {
        wrapped.count <= rows
    }

    private static func noticeLine(_ notice: WorkspaceReviewState.Notice) -> String {
        (notice.isError ? "! " : "") + clean(notice.text)
    }

    /// Every line of the review, wrapped at `width`, before any refusal.
    private static func wholeReview(
        _ review: WorkspaceReviewState, mode: CommandMode, now: Date, width: Int
    ) -> [String] {
        var lines = [header(review)]
        switch review.load {
        case .loading:
            lines.append("Loading review queue…")
        case .failed(let message):
            lines.append("Review unavailable: \(clean(message))")
        case .loaded(let items) where items.isEmpty:
            lines.append("Nothing to review.")
        case .loaded(let items):
            lines.append(contentsOf: self.rows(items, selected: review.selected, now: now, width: width))
            if let item = review.selectedItem {
                lines.append("")
                lines.append(contentsOf: detail(item))
            }
        }
        lines.append("")
        if case .reviewDenyReason(_, let input) = mode {
            lines.append("Deny reason: \(clean(input))")
        }
        if review.stale {
            let updated = review.lastUpdatedAt.map { "last updated \(age($0, now: now)) ago" } ?? "no read has landed"
            lines.append("! Review is stale · \(updated)")
        }
        if let notice = review.notice {
            lines.append(noticeLine(notice))
        }
        lines.append(hint(review, mode: mode))
        return lines.flatMap { wrap($0, width: width) }
    }

    /// Only keys valid for the selected row's state are offered.
    static func hint(_ review: WorkspaceReviewState, mode: CommandMode) -> String {
        if case .reviewDenyReason = mode { return "Enter deny · Esc back" }
        guard review.items.isEmpty == false else { return "Esc close" }
        var keys: [String] = []
        if review.action == nil, review.stale == false, review.selectionConfirmed,
           review.selectedItem?.kind == .pendingEgress {
            keys += ["a approve", "d deny"]
        }
        keys += ["j/k move", "g/G first/last", "Esc close"]
        return keys.joined(separator: " · ")
    }

    /// Header badge for the shell chrome; nil when nothing awaits a human.
    static func badge(_ review: WorkspaceReviewState) -> String? {
        let count = review.pendingCount
        guard count > 0 else { return nil }
        return "\(count) pending · Ctrl-B R"
    }

    static func header(_ review: WorkspaceReviewState) -> String {
        guard case .loaded(let items) = review.load else { return "REVIEW" }
        let blocks = items.count - review.pendingCount
        return "REVIEW  \(review.pendingCount) pending · \(blocks) \(blocks == 1 ? "block" : "blocks")"
    }

    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// Strips control and bidi scalars. Never shortens: a cut host could
    /// read as a different, benign one.
    static func clean(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// Egress detail in full. Block detail is explain output and keeps its
    /// cap, with the cut stated.
    private static func detail(_ item: ReviewItem) -> [String] {
        guard item.kind == .block, item.detail.count > detailRows else { return item.detail.map { clean($0) } }
        let hidden = item.detail.count - detailRows
        return item.detail.prefix(detailRows).map { clean($0) } + ["… \(hidden) more \(hidden == 1 ? "line" : "lines")"]
    }

    /// Hard wrap at `width` characters; every character is kept.
    static func wrap(_ line: String, width: Int) -> [String] {
        let characters = Array(line)
        guard characters.count > width else { return [line] }
        return stride(from: 0, to: characters.count, by: width).map {
            String(characters[$0..<min(characters.count, $0 + width)])
        }
    }

    /// `text` within `budget` characters, cut in the middle with a visible
    /// `…`. At least `keepingTail` trailing characters always stay, even
    /// when that overruns the budget (the line then wraps).
    static func shortened(_ text: String, to budget: Int, keepingTail minimumTail: Int) -> String {
        let characters = Array(text)
        guard characters.count > budget else { return text }
        let tail = min(characters.count, max(minimumTail, (budget - 1) / 2))
        let head = max(0, budget - 1 - tail)
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }

    /// Characters of `host:port` that must stay visible: the registrable
    /// domain (two labels, three when the second-level label is short
    /// like `co.uk`) and the port.
    static func registrableTailLength(_ summary: String) -> Int {
        guard let colon = summary.lastIndex(of: ":") else { return summary.count }
        let port = summary[colon...]
        let labels = summary[..<colon].split(separator: ".", omittingEmptySubsequences: false)
        let keep = labels.count >= 3 && labels[labels.count - 2].count <= 3 ? 3 : 2
        let domain = labels.suffix(keep).joined(separator: ".")
        return domain.count + port.count
    }

    /// A window of at most `listRows` rows that always contains the selection.
    private static func rows(_ items: [ReviewItem], selected: ReviewItemID?, now: Date, width: Int) -> [String] {
        let index = selected.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let start = max(0, min(index - listRows / 2, items.count - listRows))
        return items[start..<min(items.count, start + listRows)].map { item in
            let marker = item.id == selected ? "> " : "  "
            let label = item.kind == .pendingEgress ? "egress" : "block "
            let lead = "\(marker)\(label)  "
            let trail = " · \(age(item.at, now: now))"
            let summary = clean(item.summary)
            let tail = item.kind == .pendingEgress ? registrableTailLength(summary) : 0
            return lead + shortened(summary, to: width - lead.count - trail.count, keepingTail: tail) + trail
        }
    }
}
