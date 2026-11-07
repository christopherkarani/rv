import Foundation

/// Pure text for the review pane. No rendering, no I/O.
///
/// Every string that came from a store is untrusted: an agent can create
/// a path or a host label holding escape sequences meant to repaint the
/// pane (for example a fake "approved" line). `clean` strips control and
/// bidi scalars from each line before it reaches the terminal.
enum WorkspaceReviewText {
    static let listRows = 8
    static let detailRows = 14
    static let lineLimit = 160

    static func lines(_ review: WorkspaceReviewState, mode: CommandMode, now: Date) -> [String] {
        var lines = [header(review)]
        switch review.load {
        case .loading:
            lines.append("Loading review queue…")
        case .failed(let message):
            lines.append("Review unavailable: \(clean(message))")
        case .loaded(let items) where items.isEmpty:
            lines.append("Nothing to review.")
        case .loaded(let items):
            lines.append(contentsOf: rows(items, selected: review.selected, now: now))
            if let item = review.selectedItem {
                lines.append("")
                lines.append(contentsOf: item.detail.prefix(detailRows).map { clean($0) })
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
            lines.append((notice.isError ? "! " : "") + clean(notice.text))
        }
        lines.append(hint(review, mode: mode))
        return lines
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

    static func clean(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
        }
        return String(String(String.UnicodeScalarView(kept)).prefix(lineLimit))
    }

    /// A window of at most `listRows` rows that always contains the selection.
    private static func rows(_ items: [ReviewItem], selected: ReviewItemID?, now: Date) -> [String] {
        let index = selected.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let start = max(0, min(index - listRows / 2, items.count - listRows))
        return items[start..<min(items.count, start + listRows)].map { item in
            let marker = item.id == selected ? "> " : "  "
            let label = item.kind == .pendingEgress ? "egress" : "block "
            return "\(marker)\(label)  \(clean(item.summary)) · \(age(item.at, now: now))"
        }
    }
}
