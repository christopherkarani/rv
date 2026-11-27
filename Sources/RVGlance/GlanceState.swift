import Foundation
import RVDomain
import RVIPC

/// How the popover reaches rvd.
public enum GlanceLink: Sendable, Equatable {
    /// No reply yet. Never shown as guarding: nothing is confirmed.
    case connecting
    /// Live events are flowing.
    case live
    /// rvd answers but predates `events`: asks still show, the rest waits.
    case liveWithoutEvents
    /// rvd did not answer, or refused the read.
    case down(String)
}

/// Is every host enforcing, or is some host only watching?
public enum GlancePosture: Sendable, Equatable {
    case guarding
    /// The hosts in observe mode; empty means the machine-wide mode is observe.
    case watching([HookHost])

    /// The posture `config.json` asks for. A file rvd cannot read is enforce
    /// for rvd, so it is guarding here too; a missing file (nil) is guarding.
    public init(configJSON: Data?) {
        guard let configJSON else {
            self = .guarding
            return
        }
        self.init(config: GuardConfig(jsonData: configJSON))
    }

    /// The posture a decoded config asks for (`.empty` is guarding).
    public init(config: GuardConfig) {
        let observing = config.hosts.filter { $0.value == .observe }.map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
        if !observing.isEmpty {
            self = .watching(observing)
        } else if config.machineMode == .observe {
            self = .watching([])
        } else {
            self = .guarding
        }
    }
}

/// The last command rv stopped.
public struct GlanceStop: Sendable, Equatable {
    public var host: HookHost
    /// Redacted command or path.
    public var action: String
    /// Rule id (`core.git:reset-hard`), when rvd sent one.
    public var rule: String?
    public var at: Date

    public init(host: HookHost, action: String, rule: String?, at: Date) {
        self.host = host
        self.action = action
        self.rule = rule
        self.at = at
    }
}

/// Today's three numbers, counted from the events rvd still holds.
public struct GlanceToday: Sendable, Equatable {
    /// Local midnight these counts start at.
    public var day: Date
    public var checked = 0
    public var stopped = 0
    public var asked = 0

    public init(day: Date, checked: Int = 0, stopped: Int = 0, asked: Int = 0) {
        self.day = day
        self.checked = checked
        self.stopped = stopped
        self.asked = asked
    }
}

/// Everything the menu bar shows, as a value. `GlanceFeed` folds rvd's
/// replies into it; views only read it.
public struct GlanceState: Sendable, Equatable {
    /// How long the diamond stays red after a stop.
    public static let stopFlash: TimeInterval = 1.5
    /// Rows in the popover's Now section.
    public static let agentRows = 4

    public var link: GlanceLink = .connecting
    public var posture: GlancePosture = .guarding
    public var pending: Set<ApprovalID> = []
    public var agents: [HookHost: GlanceAgent] = [:]
    public var today: GlanceToday
    public var lastStop: GlanceStop?
    /// Running boxes. rvd has no box status yet, so this stays 0 until it does.
    public var boxesRunning = 0
    /// rv has no pause yet, so this stays nil until it does.
    public var pausedUntil: Date?
    /// Events rvd dropped before this reader saw them.
    public var missed: UInt64 = 0

    public init(today: GlanceToday) {
        self.today = today
    }

    public init(now: Date, calendar: Calendar) {
        self.init(today: GlanceToday(day: calendar.startOfDay(for: now)))
    }

    /// The diamond's state. Order matters: a dead rvd outranks everything,
    /// and a question outranks a stop that already happened.
    public func glyph(at now: Date) -> GlanceGlyph {
        switch link {
        case .connecting, .down: return .notRunning
        case .live, .liveWithoutEvents: break
        }
        if !pending.isEmpty { return .needsYou }
        if let lastStop, now >= lastStop.at, now.timeIntervalSince(lastStop.at) < Self.stopFlash {
            return .justStopped
        }
        if boxesRunning > 0 { return .boxed }
        if let pausedUntil, pausedUntil > now { return .paused }
        if case .watching = posture { return .watching }
        return .guarding
    }

    /// Hosts for the Now section, most recent first.
    public var recentAgents: [GlanceAgent] {
        Array(agents.values.sorted { lhs, rhs in
            lhs.lastAt != rhs.lastAt ? lhs.lastAt > rhs.lastAt : lhs.host.rawValue < rhs.host.rawValue
        }.prefix(Self.agentRows))
    }

    public func activeAgentCount(at now: Date) -> Int {
        agents.values.filter { !$0.isIdle(at: now) }.count
    }

    /// Starts today's counts over once local midnight has passed.
    public mutating func roll(to now: Date, calendar: Calendar) {
        let day = calendar.startOfDay(for: now)
        guard day != today.day else { return }
        today = GlanceToday(day: day)
        for host in agents.keys { agents[host]?.checkedToday = 0 }
    }

    /// Folds one `events` reply in, oldest event first.
    public mutating func apply(_ reply: EventsReply, now: Date, calendar: Calendar) {
        roll(to: now, calendar: calendar)
        link = .live
        missed += reply.missed
        for event in reply.events {
            apply(event)
        }
    }

    /// Replaces the asks with what `pendingList` holds.
    public mutating func replacePending(_ ids: [ApprovalID]) {
        pending = Set(ids)
    }

    private mutating func apply(_ event: LiveEvent) {
        let at = Date(timeIntervalSince1970: Double(event.atMs) / 1000)
        let counts = at >= today.day
        switch event.payload {
        case .decision(let decision):
            note(decision, at: at, countsToday: counts)
        case .ask(let ask):
            pending.insert(ask.item.id)
            if counts { today.asked += 1 }
        case .resolution(let resolution):
            pending.remove(resolution.id)
        case .unknown:
            break
        }
    }

    private mutating func note(_ decision: LiveDecision, at: Date, countsToday: Bool) {
        let action = decision.command ?? decision.path ?? decision.tool.rawValue
        var agent = agents[decision.host]
            ?? GlanceAgent(host: decision.host, lastAction: action, lastAt: at, checkedToday: 0)
        if at >= agent.lastAt {
            agent.lastAction = action
            agent.lastAt = at
        }
        if countsToday { agent.checkedToday += 1 }
        agents[decision.host] = agent
        guard countsToday else { return }
        today.checked += 1
        guard decision.verdict != .allowed else { return }
        today.stopped += 1
        if lastStop.map({ at >= $0.at }) ?? true {
            lastStop = GlanceStop(host: decision.host, action: action, rule: decision.rule, at: at)
        }
    }
}
