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
    /// The owner's `rv pause`: every host watched until `until`.
    case paused(until: Date)

    /// The posture `config.json` asks for. A file rvd cannot read is enforce
    /// for rvd, so it is guarding here too; a missing file (nil) is guarding.
    public init(configJSON: Data?) {
        guard let configJSON else {
            self = .guarding
            return
        }
        self.init(config: GuardConfig(jsonData: configJSON))
    }

    /// The posture a decoded config asks for (`.empty` is guarding). An
    /// open `rv pause` outranks the stored modes.
    public init(config: GuardConfig, now: Date = Date()) {
        if let pause = config.activePause(at: now) {
            self = .paused(until: pause.until)
            return
        }
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
    /// The tool the action was for, so the plain-English line can tell a
    /// command from a file path.
    public var tool: LiveTool

    public init(host: HookHost, action: String, rule: String?, at: Date, tool: LiveTool = .bash) {
        self.host = host
        self.action = action
        self.rule = rule
        self.at = at
        self.tool = tool
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

    public var link: GlanceLink = .connecting {
        didSet {
            if case .down = link { return }
            downSince = nil
        }
    }
    /// When a live rvd stopped answering; nil when it never answered.
    public private(set) var downSince: Date?
    public var posture: GlancePosture = .guarding
    /// Each ask waiting for a human, and the agent that asked.
    public var pending: [ApprovalID: HookHost] = [:]
    /// Each stop waiting for the person's unlock (K2), by code hash. The
    /// menu bar's unlock review fills it; the feed never does.
    public var unlocks: [String: GlanceUnlockAsk] = [:]
    public var agents: [HookHost: GlanceAgent] = [:]
    public var today: GlanceToday
    public var lastStop: GlanceStop?
    /// Running boxes. rvd has no box status yet, so this stays 0 until it does.
    public var boxesRunning = 0
    /// When a pause ends, if set directly; `pauseEnd` also reads the
    /// posture's `rv pause`.
    public var pausedUntil: Date?
    /// When the current pause ends: the posture's, else `pausedUntil`.
    public var pauseEnd: Date? {
        if case .paused(let until) = posture { return until }
        return pausedUntil
    }
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
        case .connecting: return .connecting
        case .down: return .notRunning
        case .live, .liveWithoutEvents: break
        }
        if !pending.isEmpty || !unlocks.isEmpty { return .needsYou }
        if let lastStop, now >= lastStop.at, now.timeIntervalSince(lastStop.at) < Self.stopFlash {
            return .justStopped
        }
        if boxesRunning > 0 { return .boxed }
        if let pauseEnd, pauseEnd > now { return .paused }
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

    /// Asks and unlockable stops waiting for the person.
    public var waitingCount: Int { pending.count + unlocks.count }

    /// The agents with an ask waiting, in a stable order.
    public var waitingHosts: [HookHost] {
        Set(pending.values).union(unlocks.values.map(\.host)).sorted { $0.rawValue < $1.rawValue }
    }

    /// rvd stopped answering. The time is kept only when it was answering
    /// before, so "stopped 2 min ago" is never a guess.
    public mutating func markDown(_ reason: String, at now: Date) {
        let wasUp = link == .live || link == .liveWithoutEvents
        let since = wasUp ? now : downSince
        link = .down(reason)
        downSince = since
        pending = [:]
        unlocks = [:]
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
    public mutating func replacePending(_ asks: [ApprovalID: HookHost]) {
        pending = asks
    }

    private mutating func apply(_ event: LiveEvent) {
        let at = Date(timeIntervalSince1970: Double(event.atMs) / 1000)
        let counts = at >= today.day
        switch event.payload {
        case .decision(let decision):
            note(decision, at: at, countsToday: counts)
        case .ask(let ask):
            pending[ask.item.id] = ask.item.host
            if counts { today.asked += 1 }
        case .resolution(let resolution):
            pending[resolution.id] = nil
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
            lastStop = GlanceStop(
                host: decision.host, action: action, rule: decision.rule, at: at, tool: decision.tool)
        }
    }
}
