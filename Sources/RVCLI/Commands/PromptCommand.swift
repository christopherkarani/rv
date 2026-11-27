import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
import RVTerm
import RVTheme

/// `rv prompt`: one glyph for a shell prompt or an agent's status line
/// (Everyday Magic, "One glyph in your prompt"). A dim `◆` when all is
/// well; words only when something needs you.
///
/// Read-only and fast. It reads the guard mode, the pending requests file
/// and today's denial rows, all local files it never writes, and asks rvd
/// one thing: hello, to learn whether it answers. It never sends rvd a
/// request. rvd gets `PromptRun.rvdBudgetMs` to answer; the prompt never
/// waits longer, and it always exits 0.
struct PromptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "One glyph for your shell prompt: guarding, watching, needs you, or down."
    )

    @Option(name: .long, help: "Colour the glyph for this shell's prompt: zsh or bash. Without it, plain text.")
    var shell: PromptShell?

    func run() async throws {
        guard let home = CLIProcess.home() else { return }
        let state = await PromptRun.state(home: home, liveness: PromptRun.liveRvd())
        let depth = ColorDepth(environment: CLIProcess.environment(), stdoutIsTTY: shell != nil)
        CommandContext.writeStdout(PromptSegment.text(state, shell: shell, depth: depth))
    }
}

/// The shell a coloured segment is for: each needs its own wrapping
/// around escapes, or the line editor miscounts the prompt's width.
enum PromptShell: String, ExpressibleByArgument, CaseIterable, Sendable {
    case zsh
    case bash
}

/// What the prompt shows, most urgent first.
enum PromptState: Equatable, Sendable {
    /// rvd did not answer hello: hooks cannot reach it.
    case down
    /// An agent waits on a person. `host` when exactly one agent asked.
    case needsYou(count: Int, host: HookHost?)
    /// Some host's guard is off: rv neither stops nor records it.
    /// `host` when exactly one host is off.
    case off(count: Int, host: HookHost?)
    /// Some host is in watch (observe) mode; `today` would-stops so far.
    case watching(today: Int)
    /// rvd did not answer within the budget: neither up nor down is known.
    /// Ranked below off and watching so it never hides them.
    case unknown
    /// Every host is guarding.
    case guarding

    init(rvd: PromptLiveness, posture: PromptPosture, waiting: [HookHost], watchedToday: Int) {
        if rvd == .down {
            self = .down
        } else if waiting.isEmpty == false {
            let hosts = Set(waiting)
            self = .needsYou(count: waiting.count, host: hosts.count == 1 ? hosts.first : nil)
        } else if case .off(let hosts) = posture {
            self = .off(count: hosts.count, host: hosts.count == 1 ? hosts.first : nil)
        } else if posture == .watching {
            self = .watching(today: watchedToday)
        } else if rvd == .unknown {
            self = .unknown
        } else {
            self = .guarding
        }
    }
}

enum PromptPosture: Equatable, Sendable {
    case guarding
    case watching
    /// The hosts whose guard is off, in name order.
    case off([HookHost])

    /// Off when any host is off; else watching when any host, or the
    /// machine, is in observe mode.
    init(config: GuardConfig) {
        let off = config.hosts.filter { $0.value == .off }.keys.sorted { $0.rawValue < $1.rawValue }
        if off.isEmpty == false {
            self = .off(off)
        } else if config.hosts.values.contains(.observe) || config.machineMode == .observe {
            self = .watching
        } else {
            self = .guarding
        }
    }
}

/// Whether rvd answered hello.
enum PromptLiveness: Equatable, Sendable {
    case up
    case down
    case unknown
}

/// The segment's words and colours.
enum PromptSegment {
    typealias Glyph = CommandVocabulary.Glyph

    static func words(_ state: PromptState) -> (glyph: Glyph, text: String) {
        switch state {
        case .down:
            return (.stopped, "rv down")
        case .needsYou(let count, let host):
            if count == 1, let host { return (.ask, "\(host.rawValue) waiting") }
            return (.ask, "\(count) waiting")
        case .off(let count, let host):
            if count == 1, let host { return (.stopped, "\(host.rawValue) off") }
            return (.stopped, "\(count) off")
        case .watching(let today):
            return (.watched, today > 0 ? "\(today)" : "")
        case .guarding:
            return (.rv, "")
        case .unknown:
            return (.rv, "?")
        }
    }

    /// `◆`, `◐ 2`, `⏺ claude waiting`, `✕ claude off`, `✕ rv down`. With a shell, the
    /// glyph and its words take rv's colour for that state, wrapped so the
    /// shell does not count the escapes.
    static func text(_ state: PromptState, shell: PromptShell?, depth: ColorDepth) -> String {
        let (glyph, words) = words(state)
        let plain = state == .unknown ? glyph.rawValue + words : [glyph.rawValue, words].filter { !$0.isEmpty }.joined(separator: " ")
        guard let shell, let code = colorCode(state, depth: depth) else { return plain }
        let (open, close) = switch shell {
        case .zsh: ("%{", "%}")
        case .bash: ("\\[", "\\]")
        }
        return "\(open)\u{1B}[\(code)m\(close)\(plain)\(open)\u{1B}[0m\(close)"
    }

    private static func colorCode(_ state: PromptState, depth: ColorDepth) -> String? {
        let ink: TermInk = switch state {
        case .down: .stop
        case .off: .stop
        case .needsYou: .watch
        case .watching: .watch
        case .guarding: .rv
        case .unknown: .mute
        }
        let tone = TermPaint.Palette(depth: depth).ink(ink)
        return TerminalInk(rgb: tone.rgb, ansi16: tone.ansi16 ?? 7).foreground(depth)
    }
}

enum PromptRun {
    /// How long the prompt waits for rvd's hello. The local reads run
    /// alongside it; the whole command stays well under 50 ms.
    static let rvdBudgetMs = 30

    /// The prompt's state from local files and one hello.
    static func state(
        home: HomeDirectory,
        liveness: @escaping @Sendable () async -> PromptLiveness,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> PromptState {
        async let rvd = liveness()
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        let posture = PromptPosture(config: GuardConfig.read(home: home))
        let waiting = PendingApprovalStore(baseDirectory: configDirectory).awaitingSnapshot(now: now).map(\.identity.agent)
        let dayStart = calendar.startOfDay(for: now)
        let watched = posture == .watching
            ? DenialLedger(configDirectory: configDirectory).records(asOf: now)
                .filter { $0.observed && $0.timestamp >= dayStart }.count
            : 0
        return PromptState(rvd: await rvd, posture: posture, waiting: waiting, watchedToday: watched)
    }

    /// Hello over the transport hooks use, raced against the budget.
    static func liveRvd() -> @Sendable () async -> PromptLiveness {
        { await hello(over: liveTransport(), budgetMs: rvdBudgetMs) }
    }

    /// Up when rvd accepts the hello, down when nothing answers the
    /// connect, unknown when it is slower than `budgetMs`. Only a hello is
    /// ever sent: `transport.send` is never called.
    ///
    /// The first answer wins and the other is left behind: a hello stuck in
    /// a blocking read never holds the prompt (the process exits after it
    /// prints).
    static func hello(over transport: (any ServiceTransport)?, budgetMs: Int) async -> PromptLiveness {
        guard let transport else { return .down }
        let (answers, answer) = AsyncStream.makeStream(of: PromptLiveness.self, bufferingPolicy: .bufferingOldest(1))
        Task.detached {
            do {
                let ack = try await transport.helloHookConsult(clientSemver: ProtocolVersion.serviceSemver)
                answer.yield(ack.protocolName == ProtocolVersion.name ? .up : .down)
            } catch ServiceTransportError.timeout {
                answer.yield(.unknown)
            } catch {
                answer.yield(.down)
            }
        }
        // A Dispatch timer, not `Task.sleep`: the deadline fires even
        // when every cooperative thread is busy.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(budgetMs)) {
            answer.yield(.unknown)
        }
        for await first in answers {
            answer.finish()
            return first
        }
        return .unknown
    }

    private static func liveTransport() -> (any ServiceTransport)? {
        #if canImport(XPC)
        XPCServiceTransport(connectTimeoutMs: rvdBudgetMs, requestTimeoutMs: rvdBudgetMs)
        #else
        ServiceClient.defaultLinuxTransport()
        #endif
    }
}
