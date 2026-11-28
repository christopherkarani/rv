import Foundation
import RVDomain
import RVIsolation

private typealias Glyph = CommandVocabulary.Glyph

/// The words of `rv box done`, the review on the way home (v4 Contained,
/// "See what changed before it lands"; v4b, "Changes come home as a
/// review"). Numbers, not adjectives. Pure.
///
/// ```
/// ◆ rv claude changed 5 files · 4 min in the box
///   src/checkout/clock.ts    +38 −4
///   test/checkout.spec.ts    +22 −17
///   … 3 more
///   ◐ notes.md · you changed it outside the box · yours stays
///   Bring it home? y yes  p pick  d drop  n keep in box
///   ✓ Home. 5 files · nothing left behind
/// ```
enum BoxDoneRender {
    /// Items listed before `… N more`.
    static let shownItems = 5
    static let trashDays = BoxTidy.trashDays

    static func review(
        _ review: BoxReview, agent: String?, now: Date, home: String?
    ) -> String {
        let time = duration(from: review.startedAt, to: now)
        var lines: [String] = []
        let files = count(review.fileCount, "file")
        if review.items.isEmpty {
            lines.append("\(Glyph.rv.rawValue) rv nothing to bring home · \(time) in the box")
        } else if let agent {
            lines.append("\(Glyph.rv.rawValue) rv \(DisplayedText.field(agent)) changed \(files) · \(time) in the box")
        } else {
            lines.append("\(Glyph.rv.rawValue) rv \(files) changed in the box · \(time)")
        }
        let shown = review.items.prefix(shownItems)
        let width = min(shown.map { DisplayedText.field($0.id).count }.max() ?? 0, 40)
        for item in shown {
            lines.append("  " + padded(DisplayedText.field(item.id), width) + "   " + numbers(item))
        }
        if review.items.count > shownItems {
            lines.append("  … \(review.items.count - shownItems) more")
        }
        lines += review.yours.map(yoursLine)
        lines += review.refused.map(refusedLine)
        return lines.joined(separator: "\n") + "\n"
    }

    /// What an item changed, in numbers.
    static func numbers(_ item: BoxReviewItem) -> String {
        switch item.shape {
        case .newFolder: return "new folder · \(count(item.fileCount, "file"))"
        case .removedFolder: return "removed folder · \(count(item.fileCount, "file"))"
        case .git: return "git data · \(count(item.fileCount, "file"))"
        case .file: break
        }
        let lines = item.lines
        switch item.kind {
        case .added?:
            return lines.map { "new · +\(grouped($0.added))" } ?? "new"
        case .removed?:
            return lines.map { "removed · −\(grouped($0.removed))" } ?? "removed"
        default:
            guard let lines else { return "changed" }
            if lines == .zero { return "mode only" }
            return "+\(grouped(lines.added)) −\(grouped(lines.removed))"
        }
    }

    static func yoursLine(_ change: BoxPathChange) -> String {
        let path = DisplayedText.field(change.relative)
        if change.kind == .bothKept, let beside = change.beside {
            return "  \(Glyph.watched.rawValue) \(path) · changed in the box and outside it · both kept, the box's is \(DisplayedText.field(beside))"
        }
        if change.saved == nil {
            return "  \(Glyph.watched.rawValue) \(path) · you removed it outside the box · it stays removed"
        }
        return "  \(Glyph.watched.rawValue) \(path) · you changed it outside the box · yours stays"
    }

    static func refusedLine(_ change: BoxPathChange) -> String {
        let path = DisplayedText.field(change.relative)
        switch change.kind {
        case .cannotComeHome(.linkLeavesProject):
            return "  \(Glyph.stopped.rawValue) \(path) · a link out of the project · can't come home, kept in the trash"
        default:
            return "  \(Glyph.stopped.rawValue) \(path) · a FIFO, socket or device file · can't come home"
        }
    }

    static let question = "  Bring it home? y yes  p pick  d drop  n keep in box "

    static func pickQuestion(_ item: BoxReviewItem) -> String {
        "  keep \(DisplayedText.field(item.id))  \(numbers(item))? y/n "
    }

    static let keptInBox = "  Kept in the box.\n  \(Glyph.next.rawValue) bring it home later: rv box done\n"

    static let notAsked = "  \(Glyph.next.rawValue) bring it home at your terminal: rv box done\n"

    static func stillRunning(_ count: Int) -> String {
        "\(Glyph.watched.rawValue) \(count == 1 ? "An agent is" : "\(count) agents are") still running in this box.\n"
            + "  \(Glyph.next.rawValue) bring it home once \(count == 1 ? "it's" : "they're") done: rv box done\n"
    }

    static func blocked(_ paths: [String]) -> String {
        let first = DisplayedText.field(paths.first ?? "")
        let more = paths.count > 1 ? " (and \(paths.count - 1) more)" : ""
        return "  \(Glyph.stopped.rawValue) \(first)\(more) changed between a file and a folder, so nothing can come home yet.\n"
            + "  \(Glyph.next.rawValue) put it back as it was in the box, then: rv box done\n"
    }

    static let noBox = "\(Glyph.done.rawValue) No box is open here.\n"

    static func unreadable(_ path: String) -> String {
        "\(Glyph.stopped.rawValue) rv can't read \(DisplayedText.field(path)) to review the box, so nothing changed.\n"
            + "  \(Glyph.next.rawValue) rv doctor\n"
    }

    static let tooLarge = "\(Glyph.stopped.rawValue) This box holds more than \(grouped(BoxHomecomingScan.maxEntries)) names, too many to review, so nothing changed.\n"
        + "  \(Glyph.next.rawValue) rv box list\n"

    static let noSource = "\(Glyph.stopped.rawValue) rv can't find what this box started from, so it can't review it. Nothing changed.\n"
        + "  \(Glyph.next.rawValue) rv doctor\n"

    static func applyFailed(_ path: String, trash: BoxTrashEntry?) -> String {
        var text = "  \(Glyph.stopped.rawValue) rv couldn't undo \(DisplayedText.field(path)) in the box, so nothing came home. The box is still open.\n"
        if let trash { text += "  Dropped work so far is in \(DisplayedText.field(trash.path)).\n" }
        return text + "  \(Glyph.next.rawValue) rv box done\n"
    }

    static func closeRefused(_ message: String) -> String {
        "  \(Glyph.stopped.rawValue) Nothing came home: \(message)\n  \(Glyph.next.rawValue) rv box done\n"
    }

    /// The last line, once the box closed.
    static func done(_ plan: BoxHomePlan) -> String {
        let trash = "in the trash for \(trashDays) days"
        let beside = plan.steps.filter { if case .placeBeside = $0 { true } else { false } }.count
        switch (plan.keptFiles, plan.droppedFiles) {
        case (0, 0) where beside > 0:
            return "  \(Glyph.done.rawValue) Closed · yours stayed, and \(count(beside, "file")) from the box \(beside == 1 ? "is" : "are") beside \(beside == 1 ? "it" : "them")\n"
        case (0, 0):
            return "  \(Glyph.done.rawValue) Closed · your project is as you left it\n"
        case (0, let dropped):
            return "  \(Glyph.done.rawValue) Dropped. \(count(dropped, "file")) \(trash) · nothing came home\n"
        case (let kept, 0):
            return "  \(Glyph.done.rawValue) Home. \(count(kept, "file")) · nothing left behind\n"
        case (let kept, let dropped):
            return "  \(Glyph.done.rawValue) Home. \(count(kept, "file")) · \(dropped) \(trash)\n"
        }
    }

    // MARK: Numbers

    /// `4 min`, `under a minute`, `2 h 5 min`, `3 days`.
    static func duration(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        switch minutes {
        case 0: return "under a minute"
        case ..<60: return "\(minutes) min"
        case ..<(48 * 60): return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
        default: return "\(minutes / (24 * 60)) days"
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(grouped(number)) \(noun)\(number == 1 ? "" : "s")"
    }

    /// `1,204`.
    static func grouped(_ number: Int) -> String {
        let digits = String(number)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count < width ? text + String(repeating: " ", count: width - text.count) : text
    }
}
