import Foundation
import RVDomain

/// One stop or would-stop as bare `rv` reads it. The CLI builds these from
/// the denial ledger; nothing here reads a file. `what` is already safe to
/// print: a rule id or a redacted path, never argv.
public struct StatusEvent: Equatable, Sendable {
    public var time: Date
    /// Host raw value (`claude`, `codex`, `tty`).
    public var agent: String
    /// `false` for an observed row: watch mode let it run.
    public var stopped: Bool
    /// A judge note in shadow, which bare `rv` leaves out like `rv log` does.
    public var isJudgeNote: Bool
    /// What the row names: the rule id, or `Read ~/.ssh/id_ed25519`.
    public var what: String

    public init(time: Date, agent: String, stopped: Bool, isJudgeNote: Bool = false, what: String) {
        self.time = time
        self.agent = agent
        self.stopped = stopped
        self.isJudgeNote = isJudgeNote
        self.what = what
    }
}

/// What bare `rv` knows about rvd.
public enum StatusService: Equatable, Sendable {
    /// rvd answered and hooks can use it.
    case running
    /// rvd is installed but did not answer, or answered skewed.
    case down
    /// No rvd is installed.
    case notInstalled
}

/// Everything bare `rv` gathers before it prints. Plain values so a test
/// can build any state without a daemon.
public struct StatusInputs: Equatable, Sendable {
    public var version: String
    public var service: StatusService
    /// Wired agents, each with the mode rvd applies to it.
    public var agents: [HookHost: GuardMode]
    /// Every command rv checked today, when a source counts them (rvd's
    /// decision log); nil leaves the count out rather than guess.
    public var commandsChecked: Int?
    public var events: [StatusEvent]
    /// False when `blocks.enabled` is off: rv keeps no rows to count.
    public var eventsRecorded: Bool
    /// Secrets rv holds for agents (names only; values are never read).
    public var secrets: Int
    public var consoleConnected: Bool

    public init(
        version: String, service: StatusService, agents: [HookHost: GuardMode],
        commandsChecked: Int? = nil, events: [StatusEvent], eventsRecorded: Bool = true,
        secrets: Int, consoleConnected: Bool
    ) {
        self.version = version
        self.service = service
        self.agents = agents
        self.commandsChecked = commandsChecked
        self.events = events
        self.eventsRecorded = eventsRecorded
        self.secrets = secrets
        self.consoleConnected = consoleConnected
    }
}

/// Bare `rv` on a terminal: "am I safe?" in four lines and the one next
/// command (North Star v2, scene 02, in the v5c words).
///
///     ◆ rv   ◐ watching 6 agents                         0.3.0
///
///     today     3 would stop  ·  0 stopped
///     last      2m  claude   core.git:push-force   ◐ would stop
///     secrets   2 locked  ·  console ● connected
///
///     → rv blocks   see what rv saw today
public struct StatusViewModel: Equatable, Sendable {
    /// Who rv covers, the header's one idea.
    public enum Coverage: Equatable, Sendable {
        /// Agents rvd covers, by mode.
        case agents(guarding: Int, watching: Int)
        /// rvd runs but no agent is wired to it.
        case noAgents
        /// rvd is installed and not answering: rv checks nothing.
        case serviceDown
        /// rv is not set up on this machine.
        case notInstalled
    }

    /// What happened to the newest command, in the v5c event words.
    public enum Verdict: Equatable, Sendable {
        case stopped
        case wouldStop

        public var glyph: CommandVocabulary.Glyph {
            switch self {
            case .stopped: .stopped
            case .wouldStop: .watched
            }
        }

        /// `✕ stopped`, `◐ would stop`.
        public var label: String { glyph.rawValue + " " + (glyph.eventWord ?? glyph.word) }
    }

    public struct Last: Equatable, Sendable {
        /// `now`, `2m`, `3h`, `2d`.
        public var age: String
        public var agent: String
        public var what: String
        public var verdict: Verdict
    }

    public struct Next: Equatable, Sendable {
        public var command: String
        public var hint: String
    }

    public var version: String
    public var coverage: Coverage
    public var commandsChecked: Int?
    public var wouldStopToday: Int
    public var stoppedToday: Int
    /// False when rv keeps no log, so the counts mean nothing.
    public var eventsRecorded: Bool
    /// The newest stop or would-stop in the window, or nil.
    public var last: Last?
    public var secrets: Int
    public var consoleConnected: Bool
    public var next: Next

    public init(_ inputs: StatusInputs, now: Date, calendar: Calendar) {
        let events = inputs.events.filter { $0.isJudgeNote == false }
        let today = events.filter { calendar.isDate($0.time, inSameDayAs: now) }
        self.version = inputs.version
        self.coverage = Self.coverage(inputs)
        self.commandsChecked = inputs.commandsChecked
        self.stoppedToday = today.filter(\.stopped).count
        self.wouldStopToday = today.count - stoppedToday
        self.eventsRecorded = inputs.eventsRecorded
        self.last = events.max { $0.time < $1.time }.map { event in
            Last(
                age: Self.age(from: event.time, to: now),
                agent: event.agent,
                what: event.what,
                verdict: event.stopped ? .stopped : .wouldStop
            )
        }
        self.secrets = inputs.secrets
        self.consoleConnected = inputs.consoleConnected
        self.next = Self.next(coverage: coverage, today: today.count)
    }

    private static func coverage(_ inputs: StatusInputs) -> Coverage {
        switch inputs.service {
        case .notInstalled:
            return .notInstalled
        case .down:
            return .serviceDown
        case .running:
            guard inputs.agents.isEmpty == false else { return .noAgents }
            let guarding = inputs.agents.values.filter { $0 == .enforce }.count
            return .agents(guarding: guarding, watching: inputs.agents.count - guarding)
        }
    }

    /// The one command worth typing next, last on screen and ready to copy.
    private static func next(coverage: Coverage, today: Int) -> Next {
        switch coverage {
        case .notInstalled:
            Next(command: CommandVocabulary.Command.setup.invocation, hint: "cover your agents")
        case .serviceDown:
            Next(command: "\(CommandVocabulary.Command.service.invocation) restart",
                 hint: "rv can't check commands until it runs")
        case .noAgents:
            Next(command: CommandVocabulary.Command.setup.invocation, hint: "connect your agents")
        case .agents:
            today > 0
                ? Next(command: logCommand, hint: "see what rv saw today")
                : Next(command: CommandVocabulary.Command.doctor.invocation, hint: "check every part of rv")
        }
    }

    /// Where the day's rows are listed.
    public static let logCommand = CommandVocabulary.Command.log.invocation

    /// Whole minutes, hours or days, never seconds: `now`, `2m`, `3h`, `2d`.
    public static func age(from time: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(time)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
