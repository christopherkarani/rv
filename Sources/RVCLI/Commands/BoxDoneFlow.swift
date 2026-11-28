import Foundation
import RVIsolation

/// Why close published nothing. Any refused publish is the end of the
/// box: the host keeps its volume as a disk image (`retainedImage`) and
/// puts the project back as it was outside the box.
struct BoxCloseRefusal: Equatable {
    /// The host's words.
    var reason: String
    /// Where the box's work is kept, when the host kept it.
    var retainedImage: String?
}

/// What `rv box done` reads from and does to the machine. `BoxDoneRun`
/// fills it from the live box; tests pass folders and closures.
struct BoxDoneMachine {
    /// The box's two trees, when it started, and what rv recorded then.
    var source: BoxHomecomingSource
    /// The box itself: the project path, where the volume is mounted.
    var boxRoot: String
    /// Runtimes running in the box now. While any are, nothing closes.
    var running: () -> Int
    /// The agent the review speaks of, when rv knows it.
    var agent: String?
    var home: String?
    var trash: BoxTrash
    var now: () -> Date
    /// Whether a person is at a terminal to answer.
    var isTerminal: Bool
    /// Shows `prompt` and returns the line typed; nil at end of input.
    var ask: (String) -> String?
    var write: (String) -> Void
    /// Closes the box: publish, then detach. Nil when it closed.
    var close: () -> BoxCloseRefusal?
}

/// The functional shell of the review on the way home: scan, show, ask,
/// look again, apply the choice to the box, close. Every exit that is not
/// `home` leaves the box open with all its work in it, or in the trash,
/// except a refused close, which says where the host kept the work.
enum BoxDoneFlow {
    enum Outcome: Equatable {
        /// The box closed; what was kept is in the project.
        case home(BoxHomePlan)
        /// Nothing came home; the box is still open.
        case keptInBox
        /// Something went wrong; nothing came home.
        case failed
    }

    /// How often the review is shown again because something changed
    /// while the person chose, before rv stops asking.
    static let rounds = 3

    static func run(_ machine: BoxDoneMachine) -> Outcome {
        if stopsForRunning(machine) { return .keptInBox }
        guard var review = scan(machine) else { return .failed }
        machine.write(BoxDoneRender.review(review, agent: machine.agent, now: machine.now(), home: machine.home))
        machine.write(BoxDoneRender.earlierTrash(earlierTrash(machine)))
        if blocks(review, machine) { return .keptInBox }
        guard machine.isTerminal else {
            machine.write(BoxDoneRender.notAsked)
            return .keptInBox
        }
        var choice = BoxHomeChoice.keepAll
        var round = 1
        // Nothing to choose: your newer edits stay and the refusals are
        // dropped whatever the answer, so close without asking.
        while review.items.isEmpty == false {
            guard let asked = self.choice(review, ask: machine.ask) else {
                machine.write(BoxDoneRender.keptInBox)
                return .keptInBox
            }
            choice = asked
            // Files can change while the question waits: the choice holds
            // only for the review it answered.
            guard let again = scan(machine) else { return .failed }
            if again == review { break }
            guard round < rounds else {
                machine.write(BoxDoneRender.keepsChanging)
                return .keptInBox
            }
            round += 1
            review = again
            machine.write(BoxDoneRender.changedWhileAsked)
            machine.write(BoxDoneRender.review(review, agent: machine.agent, now: machine.now(), home: machine.home))
            if blocks(review, machine) { return .keptInBox }
            choice = .keepAll
        }
        if stopsForRunning(machine) { return .keptInBox }
        guard machine.source.rootsMatch(boxRoot: machine.boxRoot) else {
            machine.write(BoxDoneRender.notTheBox(machine.source.project))
            return .failed
        }
        let plan = BoxHomecoming.plan(review, choice: choice)
        let trash: BoxTrashEntry?
        switch BoxHomecomingApply.apply(
            plan, savedRoot: machine.source.savedRoot, boxRoot: machine.boxRoot,
            project: machine.source.project, trash: machine.trash, now: machine.now())
        {
        case .failed(let path, let entry):
            machine.write(BoxDoneRender.applyFailed(path, trash: entry))
            return .failed
        case .applied(let entry):
            trash = entry
        }
        // The last look before publish: an agent started since, or a
        // name replaced outside the box, would make close refuse.
        let running = machine.running()
        if running > 0 {
            machine.write(BoxDoneRender.startedBeforeClose(running, trash: trash))
            return .keptInBox
        }
        if let snapshot = machine.source.snapshot {
            switch BoxHomecomingScan.replaced(savedRoot: machine.source.savedRoot, snapshot: snapshot) {
            case .success(let names) where names.isEmpty:
                break
            case .success(let names):
                machine.write(BoxDoneRender.replaced(names))
                return .keptInBox
            case .failure:
                machine.write(BoxDoneRender.unreadable(machine.source.savedRoot))
                return .failed
            }
        }
        if let refused = machine.close() {
            machine.write(BoxDoneRender.closeRefused(refused, trash: trash))
            return .failed
        }
        machine.write(BoxDoneRender.done(plan))
        return .home(plan)
    }

    /// The review as the two trees stand now; nil (and said) when they
    /// can't be read.
    private static func scan(_ machine: BoxDoneMachine) -> BoxReview? {
        switch BoxHomecomingScan.review(
            savedRoot: machine.source.savedRoot, boxRoot: machine.boxRoot,
            startedAt: machine.source.startedAt, snapshot: machine.source.snapshot)
        {
        case .failure(.unreadable(let path)):
            machine.write(BoxDoneRender.unreadable(path))
            return nil
        case .failure(.tooLarge):
            machine.write(BoxDoneRender.tooLarge)
            return nil
        case .success(let review):
            return review
        }
    }

    private static func stopsForRunning(_ machine: BoxDoneMachine) -> Bool {
        let running = machine.running()
        guard running > 0 else { return false }
        machine.write(BoxDoneRender.stillRunning(running))
        return true
    }

    /// Says what keeps anything from coming home, if something does.
    private static func blocks(_ review: BoxReview, _ machine: BoxDoneMachine) -> Bool {
        if review.blocked.isEmpty == false {
            machine.write(BoxDoneRender.blocked(review.blocked))
            return true
        }
        if review.replaced.isEmpty == false {
            machine.write(BoxDoneRender.replaced(review.replaced))
            return true
        }
        return false
    }

    /// Trash entries an earlier `rv box done` on this box made, when it
    /// stopped partway (a Ctrl-C): their work is not lost, only parked.
    static func earlierTrash(_ machine: BoxDoneMachine) -> [BoxTrashEntry] {
        let since = machine.source.startedAt.timeIntervalSince1970.rounded(.down)
        return machine.trash.entries().filter { entry in
            entry.trashedAt.timeIntervalSince1970 >= since
                && machine.trash.origin(of: entry) == machine.source.project
                && FileManager.default.fileExists(atPath: entry.path + "/" + BoxTrash.copiesFolder)
        }
    }

    /// The answer to the one question; nil keeps everything in the box.
    static func choice(_ review: BoxReview, ask: (String) -> String?) -> BoxHomeChoice? {
        switch normalized(ask(BoxDoneRender.question)) {
        case "y", "yes":
            return .keepAll
        case "d", "drop":
            return .dropAll
        case "p", "pick":
            var kept = Set<String>()
            for item in review.items {
                switch normalized(ask(BoxDoneRender.pickQuestion(item))) {
                case "y", "yes": kept.insert(item.id)
                case nil: return nil
                default: break
                }
            }
            return kept.isEmpty ? .dropAll : .keep(kept)
        default:
            return nil
        }
    }

    /// The typed word, trimmed and lowercased; nil at end of input.
    private static func normalized(_ answer: String?) -> String? {
        answer.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
