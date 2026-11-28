#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVTheme

/// `rv wait <code>`: the agent waits on rv for the person's decision on a
/// stop, instead of on the person telling it to try again. It can wait;
/// it can never decide.
///
/// What it reads, and nothing else:
/// - the unlock ledger (`AllowOnceStore.list`, the rows `rv allow-once
///   list` shows), to see the code turn into an unlock;
/// - rvd's live events (`events`, I1), as its clock and to notice rvd
///   restarting (rvd forgets the codes it issued when it restarts).
///
/// Its only service call is `events`; no redeem, attest, resolve, mint or
/// owner prompt is in reach (`WaitSeparationTests`).
struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for the person's answer to a stop, then carry on."
    )

    @Argument(help: "The code from rv's stop message (a7c835).")
    var code: String

    @Option(name: .long, help: "Give up after this many seconds (default 100, at most 3600).")
    var timeout: Int = Int(WaitRun.defaultLimit.components.seconds)

    func validate() throws {
        guard WaitCode(code) != nil else {
            throw ValidationError("A code is six letters and digits from rv's stop message, like a7c835.")
        }
        guard (1...3600).contains(timeout) else {
            throw ValidationError("--timeout takes 1 to 3600 seconds.")
        }
    }

    func run() async throws {
        guard let code = WaitCode(code), let home = CLIProcess.home() else {
            throw ExitCode(1)
        }
        let probe = ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        let palette = Palette(for: ColorCapability(probe: probe, mode: .pretty), background: probe.background)
        let owner = WaitOwnerName.from(fullName: Self.accountFullName())
        var run = WaitRun(
            ledger: LiveWaitLedger(store: AllowOnceStore.makeLive(home: home)),
            events: LiveWaitEvents(),
            limit: .seconds(timeout)
        )
        // K2: the check words go out at once, so the person can match them
        // against the menu bar's sheet while the agent waits.
        run.onStart = {
            // Unbuffered, ahead of the buffered `print`s that end the wait.
            FileHandle.standardOutput.write(Data((WaitScreen.startLine(code: code, owner: owner, palette: palette) + "\n").utf8))
        }
        let (ending, waited) = await run.wait(for: code)
        for line in WaitScreen.lines(ending, code: code, owner: owner, waited: waited, palette: palette) {
            print(line)
        }
        if ending.exitCode != 0 { throw ExitCode(ending.exitCode) }
    }

    /// The passwd full name of the account running rv (gecos), if any.
    private static func accountFullName() -> String? {
        guard let entry = getpwuid(getuid()), let gecos = entry.pointee.pw_gecos else { return nil }
        return String(cString: gecos)
    }
}

// MARK: - Ports (read-only by construction)

/// The unlock ledger's rows now. Read-only: the port has no write.
protocol WaitLedger: Sendable {
    func rows(now: Date) async -> [WaitLedgerRow]
}

/// One I1 `events` long poll. Read-only: the port has no other call.
protocol WaitEvents: Sendable {
    func poll(_ params: EventsParams) async -> WaitPoll
}

/// What one poll told `rv wait`.
enum WaitPoll: Equatable, Sendable {
    case events(EventsReply)
    /// rvd predates `events`, or is not running: wait on the ledger alone.
    case unavailable
}

struct LiveWaitLedger: WaitLedger {
    let store: AllowOnceStore

    func rows(now: Date) async -> [WaitLedgerRow] {
        await store.list(now: now).map(WaitLedgerRow.init)
    }
}

/// Events over the I1 `events` call (swap in the I2 helper here once it
/// lands). The client is private and `poll` makes only that call, plus
/// the hello its channel needs.
struct LiveWaitEvents: WaitEvents {
    private let client: ServiceClient

    init(client: ServiceClient = ServiceClient()) {
        self.client = client
    }

    func poll(_ params: EventsParams) async -> WaitPoll {
        switch await client.liveEvents(params) {
        case .success(.events(let reply)): return .events(reply)
        case .success(.unsupported), .failure: return .unavailable
        }
    }
}

// MARK: - The loop (shell)

/// Waits for one code's answer: re-reads the ledger after every poll, and
/// ends at an answer, at rvd restarting, or at `limit`.
struct WaitRun: Sendable {
    /// Under the 2 minute default of an agent's shell tool, so the agent
    /// sees "still waiting" instead of a killed command.
    static let defaultLimit: Duration = .seconds(100)
    /// The longest one poll waits: how stale the ledger read can be.
    static let pollWaitMs = 1_000

    let ledger: any WaitLedger
    let events: any WaitEvents
    let limit: Duration
    var clock: @Sendable () -> Date = { Date() }
    var monotonic: @Sendable () -> ContinuousClock.Instant = { .now }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Runs once the code is known to be a live stop, before the first poll.
    var onStart: @Sendable () -> Void = {}

    func wait(for code: WaitCode) async -> (WaitEnding, Duration) {
        let started = monotonic()
        guard let ask = WaitWatch.ask(for: code, in: await ledger.rows(now: clock())) else {
            return (.unknownCode, .zero)
        }
        onStart()
        var stream: UUID?
        var cursor: UInt64?
        while true {
            let state = WaitWatch.state(of: ask, in: await ledger.rows(now: clock()))
            if state.isFinal { return (.finished(state), monotonic() - started) }
            let left = limit - (monotonic() - started)
            guard left > .zero else { return (.stillWaiting, monotonic() - started) }
            let waitMs = min(Self.pollWaitMs, max(1, Int(left / .milliseconds(1))))
            let pollStart = monotonic()
            switch await events.poll(EventsParams(stream: stream, after: cursor, waitMs: waitMs)) {
            case .events(let reply):
                // A new stream after one we saw: rvd restarted and forgot
                // the code. The ledger cannot know that.
                if let seen = stream, seen != reply.stream {
                    return (.finished(.rvdRestarted), monotonic() - started)
                }
                stream = reply.stream
                cursor = reply.cursor
                // An answer at once with nothing in it: rvd is at its
                // waiter cap. Back off instead of spinning.
                if reply.events.isEmpty, monotonic() - pollStart < .milliseconds(50) {
                    await sleep(.milliseconds(Self.pollWaitMs))
                }
            case .unavailable:
                await sleep(.milliseconds(Self.pollWaitMs))
            }
        }
    }
}
