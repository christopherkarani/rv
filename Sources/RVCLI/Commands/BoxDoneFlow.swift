import Foundation
import RVIsolation

/// What `rv box done` reads from and does to the machine. `BoxDoneRun`
/// fills it from the live box; tests pass folders and closures.
struct BoxDoneMachine {
    /// The box's two trees and when it started.
    var source: BoxHomecomingSource
    /// The box itself: the project path, where the volume is mounted.
    var boxRoot: String
    /// Runtimes still running in the box. While any are, nothing closes.
    var stillRunning: Int
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
    /// Closes the box: publish, then detach. Nil when it closed, else the
    /// host's words for why nothing was published.
    var close: () -> String?
}

/// The functional shell of the review on the way home: scan, show, ask,
/// apply the choice to the box, close. Every exit that is not `home`
/// leaves the box open with all its work in it, or in the trash.
enum BoxDoneFlow {
    enum Outcome: Equatable {
        /// The box closed; what was kept is in the project.
        case home(BoxHomePlan)
        /// Nothing changed; the box is still open.
        case keptInBox
        /// Something went wrong before the box closed; it is still open.
        case failed
    }

    static func run(_ machine: BoxDoneMachine) -> Outcome {
        if machine.stillRunning > 0 {
            machine.write(BoxDoneRender.stillRunning(machine.stillRunning))
            return .keptInBox
        }
        let review: BoxReview
        switch BoxHomecomingScan.review(
            savedRoot: machine.source.savedRoot, boxRoot: machine.boxRoot, startedAt: machine.source.startedAt)
        {
        case .failure(.unreadable(let path)):
            machine.write(BoxDoneRender.unreadable(path))
            return .failed
        case .failure(.tooLarge):
            machine.write(BoxDoneRender.tooLarge)
            return .failed
        case .success(let value):
            review = value
        }
        machine.write(BoxDoneRender.review(review, agent: machine.agent, now: machine.now(), home: machine.home))
        if review.blocked.isEmpty == false {
            machine.write(BoxDoneRender.blocked(review.blocked))
            return .keptInBox
        }
        guard machine.isTerminal else {
            machine.write(BoxDoneRender.notAsked)
            return .keptInBox
        }
        let choice: BoxHomeChoice
        if review.items.isEmpty {
            // Nothing to choose: your newer edits stay and the refusals
            // are dropped whatever the answer, so close without asking.
            choice = .keepAll
        } else {
            guard let asked = self.choice(review, ask: machine.ask) else {
                machine.write(BoxDoneRender.keptInBox)
                return .keptInBox
            }
            choice = asked
        }
        let plan = BoxHomecoming.plan(review, choice: choice)
        switch BoxHomecomingApply.apply(
            plan, savedRoot: machine.source.savedRoot, boxRoot: machine.boxRoot,
            project: machine.source.project, trash: machine.trash, now: machine.now())
        {
        case .failed(let path, let trash):
            machine.write(BoxDoneRender.applyFailed(path, trash: trash))
            return .failed
        case .applied:
            break
        }
        if let refused = machine.close() {
            machine.write(BoxDoneRender.closeRefused(refused))
            return .failed
        }
        machine.write(BoxDoneRender.done(plan))
        return .home(plan)
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
