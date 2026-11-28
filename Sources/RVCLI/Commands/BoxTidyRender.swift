import Foundation
import RVDomain
import RVIsolation

private typealias Glyph = CommandVocabulary.Glyph

/// `rv box tidy`'s words (v4 Contained, "Leftovers tidy themselves").
/// Pure; `BoxTidyRun` reads the machine and moves files.
///
/// ```
/// ◆ rv 3 boxes never finished · 253 old images
///   ◐ ~/code/app    may hold unsaved work · Nov 19 · cd ~/code/app && rv box
///   Move 253 to trash? Boxes with unsaved work stay. y/n
///   ✓ Tidied · trash empties in 7 days
/// ```
enum BoxTidyRender {
    /// The heading and one line per box kept.
    /// Open boxes are kept too but not listed: `rv box list` shows them.
    static func summary(_ plan: BoxTidyPlan, home: String?, timeZone: TimeZone = .current) -> String {
        let listed = unfinished(plan)
        var facts: [String] = []
        if listed.isEmpty == false {
            facts.append("\(listed.count) \(listed.count == 1 ? "box" : "boxes") never finished")
        }
        if plan.moves.isEmpty == false {
            facts.append("\(plan.moves.count) old \(plan.moves.count == 1 ? "image" : "images")")
        }
        if plan.expired.isEmpty == false {
            facts.append("\(plan.expired.count) in the trash past \(BoxTidy.trashDays) days")
        }
        guard facts.isEmpty == false else { return "\(Glyph.done.rawValue) Nothing to tidy.\n" }
        var lines = ["\(Glyph.rv.rawValue) rv \(facts.joined(separator: " · "))"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        let places = listed.map { DisplayedText.field(BoxPlan.displayPath($0.project, home: home)) }
        let width = min(places.map(\.count).max() ?? 0, 40)
        for (box, place) in zip(listed, places) {
            let padded = place.count < width ? place + String(repeating: " ", count: width - place.count) : place
            var parts = [boxWords(box.state), formatter.string(from: box.lastActive)]
            if let next = next(box, home: home) { parts.append(next) }
            lines.append("  \(Glyph.watched.rawValue) \(padded)   \(parts.joined(separator: " · "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Why nothing moves this run, and when to try again.
    static func holdText(_ hold: BoxTidyHold, home: String?) -> String {
        switch hold {
        case .boxBusy(let project):
            let place = DisplayedText.field(BoxPlan.displayPath(project, home: home))
            return "  \(Glyph.watched.rawValue) Nothing moved: the box for \(place) is still starting.\n"
                + "  \(Glyph.next.rawValue) run it again once that box is open: rv box tidy\n"
        case .attachedUnknown:
            return "  \(Glyph.stopped.rawValue) Nothing moved: rv could not read which images are in use.\n"
                + "  \(Glyph.next.rawValue) rv doctor\n"
        }
    }

    /// The one yes. Asked only when something would move or be emptied:
    /// emptying the expired trash waits for a yes too.
    static func question(_ plan: BoxTidyPlan) -> String {
        let listed = unfinished(plan)
        let stays = listed.isEmpty
            ? ""
            : listed.count == 1 ? " The box with unsaved work stays." : " Boxes with unsaved work stay."
        let ask = switch (plan.moves.count, plan.expired.count) {
        case (let moves, 0): "Move \(moves) to trash?"
        case (0, let expired): "Empty \(expired) from the trash for good?"
        case (let moves, let expired): "Move \(moves) to trash and empty \(expired) for good?"
        }
        return "  \(ask)\(stays) y/n "
    }

    /// No terminal to ask on: nothing changes; say the command that tidies.
    static let notAsked = "  \(Glyph.next.rawValue) nothing changed; to tidy: rv box tidy --yes\n"

    static let declined = "  Nothing moved.\n"

    /// `asked`: how many leftovers the question named. When fewer were
    /// acted on (a box claimed one after the yes), the rest wait.
    static func done(_ outcome: BoxTidyOutcome, asked: Int? = nil) -> String {
        var text = ""
        if outcome.moved > 0 || outcome.emptied > 0 {
            var parts = ["\(Glyph.done.rawValue) Tidied"]
            if outcome.moved > 0 { parts.append("trash empties in \(BoxTidy.trashDays) days") }
            if outcome.emptied > 0 {
                parts.append("emptied \(outcome.emptied) from the trash")
            }
            text += "  " + parts.joined(separator: " · ") + "\n"
        }
        if outcome.stayed > 0 {
            text += "  \(Glyph.watched.rawValue) \(outcome.stayed) could not move: still in use or on another disk.\n"
            text += "  \(Glyph.next.rawValue) rv workspace leftovers\n"
        }
        if let asked {
            let left = asked - outcome.moved - outcome.emptied - outcome.stayed
            if left > 0 {
                text += "  \(Glyph.watched.rawValue) \(left) left alone: in use since you were asked.\n"
            }
        }
        if text.isEmpty { text = "  Nothing moved.\n" }
        return text
    }

    /// Kept boxes that are not open now.
    static func unfinished(_ plan: BoxTidyPlan) -> [BoxTidyBox] {
        plan.kept.filter { $0.state != .open }
    }

    /// A kept box, in plain words. Every one may hold unsaved work.
    static func boxWords(_ state: BoxTidyBox.State) -> String {
        switch state {
        case .open: "open"
        case .busy: "starting"
        case .unfinished: "may hold unsaved work"
        }
    }

    /// The command that finishes an unfinished box: `rv box` in its
    /// folder recovers it on start. (`rv box <path>` would run the path as
    /// a command, so the line changes folder first.)
    static func next(_ box: BoxTidyBox, home: String?) -> String? {
        guard box.state == .unfinished else { return nil }
        return "cd \(BoxPlan.shellPath(box.project, home: home)) && rv box"
    }
}
