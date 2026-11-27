import Foundation
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
import RVPresentation
import RVService
import RVTheme
import Synchronization
import Testing
@testable import RVCLI

/// Bare `rv` on a terminal (C4): four lines and the next command.
@Suite("StatusCommand")
struct StatusCommandTests {
    private static let now = Date(timeIntervalSince1970: 1_764_252_000)  // a fixed afternoon, UTC

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func render(_ inputs: StatusInputs) -> String {
        StatusRun.text(inputs, now: now, calendar: utc, palette: colorOffPalette)
    }

    private static let watchedPush = StatusEvent(
        time: now.addingTimeInterval(-120), agent: "claude", stopped: false, what: "core.git:push-force"
    )

    // MARK: - Goldens

    @Test func watchingSixAgentsReadsAsTheV2Screen() {
        let agents: [HookHost: GuardMode] = [
            .claude: .observe, .codex: .observe, .cursor: .observe,
            .grok: .observe, .pi: .observe, .opencode: .observe,
        ]
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: agents,
            events: [
                Self.watchedPush,
                StatusEvent(time: Self.now.addingTimeInterval(-900), agent: "codex", stopped: false,
                            what: "core.filesystem:rm-rf"),
                StatusEvent(time: Self.now.addingTimeInterval(-1_800), agent: "claude", stopped: false,
                            what: "core.git:reset-hard"),
            ],
            secrets: 2, consoleConnected: true
        ))
        #expect(text == """

              ◆ rv   ◐ watching 6 agents                         0.3.0

              today     3 would stop  ·  0 stopped
              last      2m  claude   core.git:push-force   ◐ would stop
              secrets   2 locked  ·  console ● connected

              → rv blocks   see what rv saw today

            """)
    }

    @Test func guardingWithAStopToday() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .enforce],
            commandsChecked: 412,
            events: [StatusEvent(time: Self.now.addingTimeInterval(-7_200), agent: "claude", stopped: true,
                                 what: "core.git:reset-hard")],
            secrets: 0, consoleConnected: false
        ))
        #expect(text == """

              ◆ rv   ● guarding 1 agent                          0.3.0

              today     412 commands checked  ·  0 would stop  ·  1 stopped
              last      2h  claude   core.git:reset-hard   ✕ stopped
              secrets   0 locked  ·  console not connected

              → rv blocks   see what rv saw today

            """)
    }

    @Test func mixedModesNameBoth() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .enforce, .codex: .enforce, .cursor: .observe],
            events: [], secrets: 1, consoleConnected: false
        ))
        #expect(text.contains("◆ rv   ● guarding 2 agents  ·  ◐ watching 1"))
        #expect(text.contains("last      nothing stopped this week"))
        #expect(text.hasSuffix("  → rv doctor   check every part of rv\n"))
    }

    @Test func rvdDownSaysSoAndNamesTheRestart() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .down, agents: [.claude: .observe],
            events: [Self.watchedPush], secrets: 0, consoleConnected: false
        ))
        #expect(text.contains("◆ rv   ✕ rvd is not running"))
        #expect(text.hasSuffix("  → rv service restart   rv can't check commands until it runs\n"))
    }

    @Test func notSetUpPointsAtSetup() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .notInstalled, agents: [:], events: [], secrets: 0, consoleConnected: false
        ))
        #expect(text.contains("◆ rv   ○ not set up"))
        #expect(text.hasSuffix("  → rv setup   cover your agents\n"))
    }

    @Test func runningWithNoAgentsPointsAtSetup() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: [:], events: [], secrets: 0, consoleConnected: false
        ))
        #expect(text.contains("● running, no agents connected"))
        #expect(text.hasSuffix("  → rv setup   connect your agents\n"))
    }

    @Test func ledgerOffSaysNothingIsCounted() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .observe],
            events: [], eventsRecorded: false, secrets: 0, consoleConnected: false
        ))
        #expect(text.contains("today     not counted, rv keeps no log"))
        #expect(text.contains("last      not kept"))
    }

    @Test func statusIsFourLinesAndTheNextCommandLast() {
        let text = Self.render(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .observe],
            events: [Self.watchedPush], secrets: 2, consoleConnected: true
        ))
        let lines = text.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
        #expect(lines.count == 5)
        #expect(lines.last?.contains("→ rv blocks") == true)
    }

    // MARK: - Counting

    @Test func judgeNotesInShadowAreLeftOut() {
        let model = StatusViewModel(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .observe],
            events: [
                StatusEvent(time: Self.now.addingTimeInterval(-60), agent: "claude", stopped: false,
                            isJudgeNote: true, what: "core.judge:laya-block"),
                Self.watchedPush,
            ],
            secrets: 0, consoleConnected: false
        ), now: Self.now, calendar: Self.utc)
        #expect(model.wouldStopToday == 1)
        #expect(model.last?.what == "core.git:push-force")
    }

    @Test func yesterdayCountsForLastButNotToday() {
        let model = StatusViewModel(StatusInputs(
            version: "0.3.0", service: .running, agents: [.claude: .observe],
            events: [StatusEvent(time: Self.now.addingTimeInterval(-2 * 86_400), agent: "codex", stopped: true,
                                 what: "core.git:reset-hard")],
            secrets: 0, consoleConnected: false
        ), now: Self.now, calendar: Self.utc)
        #expect(model.stoppedToday == 0)
        #expect(model.last?.age == "2d")
        #expect(model.next.command == CommandVocabulary.Command.doctor.invocation)
    }

    @Test(arguments: [(0, "now"), (59, "now"), (60, "1m"), (3_599, "59m"), (3_600, "1h"), (86_400, "1d")])
    func ageIsWholeUnits(seconds: Int, label: String) {
        #expect(StatusViewModel.age(from: Self.now.addingTimeInterval(-Double(seconds)), to: Self.now) == label)
    }

    // MARK: - Gathering

    @Test func gatherReadsTheLedgerSecretsAndAHealthyRvdWithoutCompilingPacks() async throws {
        let home = try isolatedHome()
        let configDirectory = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let ledger = DenialLedger(configDirectory: configDirectory)
        ledger.append(DenialLedgerRecord(
            timestamp: Self.now.addingTimeInterval(-300), host: .hook(.claude), tool: .file(.read),
            ruleID: RuleID(rawValue: "core.secrets:read")!, category: .secret(.ssh),
            path: "~/.ssh/id_ed25519", observed: true
        ), now: Self.now)
        ledger.append(DenialLedgerRecord(
            timestamp: Self.now.addingTimeInterval(-240), host: .hook(.claude), tool: .bash,
            ruleID: RuleID(rawValue: "core.judge:laya-block")!, category: .pack(.coreJudge),
            path: "", observed: true
        ), now: Self.now)
        let keychain = FakeKeychain()
        let secrets = SecretsEnvironment(
            configDirectory: configDirectory, resolver: keychain.resolver(host: [:]), keychain: keychain.writer)
        _ = try SecretsRun.set(
            name: "OPENAI_API_KEY", value: Data("sk-live-do-not-print".utf8), definition: .environment,
            agents: [], description: nil, environment: secrets).get()

        let sessions = Mutex(0)
        let client = ServiceClient(
            transport: Self.healthyRvd(),
            lazySession: {
                sessions.withLock { $0 += 1 }
                return EvaluateSession()
            },
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home
        )
        let inputs = await StatusRun.gather(home: home, client: client, environment: [:], now: Self.now)

        #expect(sessions.withLock { $0 } == 0)
        #expect(inputs.service == .running)
        #expect(inputs.secrets == 1)
        #expect(inputs.events.count == 2)
        let text = StatusRun.text(inputs, now: Self.now, calendar: Self.utc, palette: colorOffPalette)
        #expect(text.contains("today     1 would stop  ·  0 stopped"))
        #expect(text.contains("last      5m  claude   Read ~/.ssh/id_ed25519   ◐ would stop"))
        #expect(text.contains("secrets   1 locked"))
        #expect(text.contains("sk-live-do-not-print") == false)
        #expect(text.contains("OPENAI_API_KEY") == false)
    }

    @Test func gatherWithNoRvdIsDownOrNotInstalledAndStillQuick() async throws {
        let home = try isolatedHome()
        let sessions = Mutex(0)
        let client = ServiceClient(
            transport: nil,
            lazySession: {
                sessions.withLock { $0 += 1 }
                return EvaluateSession()
            },
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            home: home
        )
        let inputs = await StatusRun.gather(home: home, client: client, environment: [:], now: Self.now)
        #expect(inputs.service == .notInstalled)
        #expect(sessions.withLock { $0 } == 0)
    }

    @Test func ledgerRowsBecomeEventsWithoutArgv() {
        let bash = StatusRun.event(DenialLedgerRecord(
            timestamp: Self.now, host: .hook(.codex), tool: .bash, ruleID: RuleID(rawValue: "core.git:reset-hard")!,
            category: .pack(.coreGit), path: ""
        ))
        #expect(bash == StatusEvent(time: Self.now, agent: "codex", stopped: true, what: "core.git:reset-hard"))
        let judge = StatusRun.event(DenialLedgerRecord(
            timestamp: Self.now, host: .hook(.claude), tool: .bash, ruleID: RuleID(rawValue: "core.judge:laya-block")!,
            category: .pack(.coreJudge), path: "", observed: true
        ))
        #expect(judge.isJudgeNote)
    }

    static func healthyRvd() -> ScriptedTransport {
        ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: ProtocolVersion.serviceSemver, status: .ok),
            responseResult: .doctorSnapshot(DoctorSnapshotReply(
                state: .running, idleExitSeconds: 300, packsEnabled: dayOnePackIDs,
                checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
            ))
        )
    }
}
