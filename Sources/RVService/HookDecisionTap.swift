import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVIPC
import Synchronization

/// The one hook point on rvd's decision path (workstream I). rvd wraps
/// each hookEvaluate's world with `tapping`, so the evaluation it replies
/// with is captured on the request's own task (where the host session is
/// bound), and publishes it once, after `HookDoor.run` has produced the
/// reply, with the reply's final timeout state (`publish`).
///
/// Every decision consumer subscribes to the bus (`LiveEventBus`); none
/// adds a second write on the hook path.
final class HookDecisionTap: Sendable {
    /// What one evaluation decided, raw. Never leaves rvd unredacted.
    struct Capture: Sendable {
        enum Subject: Sendable {
            case shell(ShellCommand)
            case file(FileToolAction)
        }

        let result: EvaluationResult
        let subject: Subject
        let cwd: WorkingDirectory?
        let host: HookHost
        /// Wall clock just before evaluation started.
        let startedAt: Date
        /// The host session id, when it is an opaque token.
        let session: String?
    }

    private let captured = Mutex<Capture?>(nil)

    init() {}

    /// The evaluation captured for this request, if one ran.
    var capture: Capture? { captured.withLock { $0 } }

    /// `world` with its two evaluate ports recording into this tap. Mint,
    /// pending and the evaluation itself are untouched.
    func tapping(
        _ world: HookEvaluateWorld, host: HookHost, clock: @escaping @Sendable () -> Date
    ) -> HookEvaluateWorld {
        var tapped = world
        tapped.evaluate = { command, cwd in
            let started = clock()
            let result = await world.evaluate(command, cwd)
            self.record(result, .shell(command), cwd: cwd, host: host, startedAt: started)
            return result
        }
        tapped.evaluateFile = { action, cwd in
            let started = clock()
            let result = await world.evaluateFile(action, cwd)
            self.record(result, .file(action), cwd: cwd, host: host, startedAt: started)
            return result
        }
        return tapped
    }

    /// Runs on the request's task: `HookSessionAttribution` is a task-local
    /// that `hookWire` binds around the evaluation.
    private func record(
        _ result: EvaluationResult, _ subject: Capture.Subject, cwd: WorkingDirectory?, host: HookHost,
        startedAt: Date
    ) {
        let session = HookSessionAttribution.current.flatMap {
            DenialLedgerRecord.attributableSession($0.rawValue)
        }
        captured.withLock {
            $0 = Capture(result: result, subject: subject, cwd: cwd, host: host, startedAt: startedAt, session: session)
        }
    }

    /// Publishes the captured decision to `bus`, off the hook's task: the
    /// redaction and the publish run on a detached utility task, so the
    /// reply never waits for them. `timedOut` is the reply's final state
    /// (`HookDeadline.requiresTimeoutReply`, read after `HookDoor.run`).
    /// No capture (the request timed out before evaluating, or was not a
    /// tool call) publishes nothing.
    func publish(to bus: LiveEventBus, timedOut: Bool, home: HomePath?) {
        guard let capture else { return }
        Task.detached(priority: .utility) {
            bus.publish(.decision(capture.liveDecision(timedOut: timedOut, home: home)), at: capture.startedAt)
        }
    }
}

extension HookDecisionTap.Capture {
    /// The rule a timed-out reply is filed under: the door answered with
    /// its timeout deny, whatever the evaluation found.
    static let timeoutRule = "rv.timeout"

    /// The redacted decision the agent saw. Pure.
    func liveDecision(timedOut: Bool, home: HomePath?) -> LiveDecision {
        let verdict: LiveVerdict
        let rule: String?
        if timedOut {
            verdict = .refused
            rule = Self.timeoutRule
        } else {
            switch result.decision {
            case .allow:
                verdict = .allowed
                rule = nil
            case .deny(let deny):
                verdict = .denied
                rule = deny.ruleID.rawValue
            case .indeterminate(let reason):
                verdict = .refused
                rule = GatedEvaluate.indeterminateRuleID(reason).rawValue
            }
        }
        let tool: LiveTool
        var command: String?
        var path: String?
        switch subject {
        case .shell(let shell):
            tool = .bash
            command = LiveEventRedaction.command(shell.rawValue, home: home)
        case .file(let action):
            switch action.kind {
            case .read: tool = .read
            case .edit: tool = .edit
            case .write: tool = .write
            }
            path = LiveEventRedaction.path(action.path.rawValue, home: home)
        }
        let shownCwd = cwd.map { LiveEventRedaction.path($0.rawValue, home: home) }
        return LiveDecision(
            verdict: verdict, host: host, tool: tool, command: command, path: path,
            cwd: shownCwd?.isEmpty == false ? shownCwd : nil, rule: rule, session: session, timedOut: timedOut
        )
    }
}

/// How a live decision hides what it must not carry: credential-shaped
/// tokens (`ReviewSanitizer.redactCredentials`), the home directory
/// (`DenialPathRedaction` for paths), control characters, and anything
/// past `LiveDecision.maxTextBytes`. The same recipe as the local decision
/// log (J1b `DecisionRedaction`); once both land, one calls the other.
enum LiveEventRedaction {
    static func command(_ raw: String, home: HomePath?) -> String {
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        let redacted = homeShown(in: ReviewSanitizer.redactCredentials(in: flattened), home: home)
        return capped(redacted.trimmingCharacters(in: .whitespaces), bytes: LiveDecision.maxTextBytes)
    }

    static func path(_ raw: String, home: HomePath?) -> String {
        capped(DenialPathRedaction.redact(raw, home: home), bytes: LiveDecision.maxTextBytes)
    }

    /// Every whole occurrence of the home path becomes `~`: followed by the
    /// end, a separator or punctuation, never by more of a longer name
    /// (`/Users/ann` stays in `/Users/anna`).
    static func homeShown(in text: String, home: HomePath?) -> String {
        guard let home, home.rawValue.count > 1 else { return text }
        let homePath = home.rawValue.hasSuffix("/") ? String(home.rawValue.dropLast()) : home.rawValue
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: homePath) {
            let next = rest[range.upperBound...].first
            let continuesName = next.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } ?? false
            result += rest[..<range.lowerBound]
            result += continuesName ? rest[range] : "~"
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    static func capped(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            guard used + size <= limit else { break }
            kept.append(character)
            used += size
        }
        return kept + "…"
    }
}
