import Foundation
import RVDomain
import RVHistory
import RVIPC
import RVPolicy
import RVTerm
import Synchronization
import Testing
@testable import RVCLI

// MARK: - rv check

@Suite("rv check")
struct CheckCommandTests {
    @Test("arguments win; stdin lines skip blanks and # comments")
    func planSteps() throws {
        #expect(try CheckPlan.steps(arguments: [" ls ", "git status"], stdin: "rm -rf /").get() == ["ls", "git status"])
        let fromStdin = try CheckPlan.steps(arguments: [], stdin: "# plan\nnpm test\n\n  git push  \n").get()
        #expect(fromStdin == ["npm test", "git push"])
    }

    @Test("an empty plan, an empty step, too many or too long steps are refused")
    func planProblems() {
        #expect(throws: CheckPlan.Problem.self) { try CheckPlan.steps(arguments: [], stdin: nil).get() }
        #expect(throws: CheckPlan.Problem.self) { try CheckPlan.steps(arguments: [], stdin: "# only\n\n").get() }
        #expect(throws: CheckPlan.Problem.self) { try CheckPlan.steps(arguments: ["ls", "  "], stdin: nil).get() }
        let many = Array(repeating: "ls", count: CheckPlan.maxSteps + 1)
        #expect(throws: CheckPlan.Problem.self) { try CheckPlan.steps(arguments: many, stdin: nil).get() }
        let long = String(repeating: "a", count: CheckPlan.maxStepBytes + 1)
        #expect(throws: CheckPlan.Problem.self) { try CheckPlan.steps(arguments: [long], stdin: nil).get() }
    }

    @Test("stdin is not read when commands are passed, even from an open pipe")
    func argumentsSkipStdin() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        // The write end stays open: reading would block forever.
        let input = CheckPlan.input(arguments: ["ls"], stdinIsTTY: false, stdin: pipe.fileHandleForReading)
        #expect(try input.get() == nil)
        #expect(try CheckPlan.input(arguments: [], stdinIsTTY: true, stdin: pipe.fileHandleForReading).get() == nil)
    }

    @Test("stdin is read to its end, and refused past the limit")
    func stdinLimit() throws {
        let small = Pipe()
        small.fileHandleForWriting.write(Data("ls\npwd\n".utf8))
        try small.fileHandleForWriting.close()
        #expect(try CheckPlan.input(arguments: [], stdinIsTTY: false, stdin: small.fileHandleForReading).get() == "ls\npwd\n")

        let large = Pipe()
        let writer = Thread {
            large.fileHandleForWriting.write(Data(repeating: UInt8(ascii: "a"), count: 4096))
            try? large.fileHandleForWriting.close()
        }
        writer.start()
        let refused = CheckPlan.input(arguments: [], stdinIsTTY: false, stdin: large.fileHandleForReading, limit: 1024)
        #expect(throws: CheckPlan.Problem.self) { try refused.get() }
        #expect(CheckPlan.maxStdinBytes == CheckPlan.maxSteps * CheckPlan.maxStepBytes)
        #expect(CheckPlan.maxSteps == 20)
    }

    @Test("an agent's check sees its own guard mode")
    func checksAsTheHost() async throws {
        let home = try isolatedHome()
        let config = RVPolicyPaths.configDirectory(home: home)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"guard":{"hosts":{"claude":"observe"}}}"#.utf8).write(to: config.appendingPathComponent("config.json"))
        #expect(GuardConfig.read(home: home).hosts[.claude] == .observe)
        let cwd = WorkingDirectory(validating: home.path)
        // A deny watch mode relaxes (unlike the observe floor's `rm -rf /`).
        let asClaude = await CheckRun.report(steps: ["git clean -fdx"], cwd: cwd, home: home, host: .hook(.claude))
        let asPerson = await CheckRun.report(steps: ["git clean -fdx"], cwd: cwd, home: home)
        #expect(asClaude.steps[0].outcome == .wouldStop)
        #expect(asPerson.steps[0].outcome.needsPerson)
    }

    @Test("exit 0 when only fine and watched steps; 1 when a step needs a person")
    func exitCodes() {
        let fine = CheckStep(command: "ls", outcome: .fine)
        let watched = CheckStep(command: "rm -rf build", outcome: .wouldStop, rule: "r", reason: "deletes")
        #expect(CheckReport(steps: [fine, watched]).exitCode == 0)
        for outcome in [CheckOutcome.asks, .stops, .incomplete] {
            let step = CheckStep(command: "x", outcome: outcome, rule: "r", reason: "why")
            #expect(CheckReport(steps: [fine, step]).exitCode == 1)
        }
    }

    @Test("text names each step with its glyph, the first one to explain, and approves nothing")
    func reportText() {
        let report = CheckReport(steps: [
            CheckStep(command: "npm test", outcome: .fine),
            CheckStep(command: "git push --force origin main", outcome: .stops, rule: "git.force", reason: "rewrites main"),
            CheckStep(command: "rm -rf build", outcome: .wouldStop, rule: "fs.rm", reason: "deletes files"),
        ])
        let text = report.text
        #expect(text.hasPrefix("◆ 3 steps · 1 fine · 1 needs a person · 1 watched\n"))
        #expect(text.contains("  ✓ npm test\n"))
        #expect(text.contains("  ✕ git push --force origin main   rewrites main"))
        #expect(text.contains("  ◐ rm -rf build") && text.contains("would stop · runs in watch mode · deletes files"))
        #expect(text.contains("→ rv why 'git push --force origin main'"))
        #expect(text.contains("rv check approves nothing"))
    }

    @Test("an all-fine plan has no next step and no approval note")
    func allFine() {
        let text = CheckReport(steps: [CheckStep(command: "ls", outcome: .fine)]).text
        #expect(text == "◆ 1 step · 1 fine\n  ✓ ls\n")
    }

    @Test("long commands are clipped; quotes in the explain hint are escaped")
    func clipAndQuote() {
        let long = "echo '" + String(repeating: "x", count: 80) + "'"
        let text = CheckReport(steps: [CheckStep(command: long, outcome: .asks, rule: "r", reason: "why")]).text
        #expect(text.contains("…   asks a person · why"))
        #expect(text.contains("rv why 'echo '\\''x"))
    }

    @Test("first sentence keeps one step on one line")
    func firstSentence() {
        #expect(CheckRun.firstSentence("Deletes files. Run it yourself.") == "Deletes files")
        #expect(CheckRun.firstSentence("line one\nline two.") == "line one line two")
    }

    @Test("robot JSON is rv.check.v1 with each step's outcome")
    func robot() throws {
        let report = CheckReport(steps: [CheckStep(command: "rm -rf build", outcome: .wouldStop, rule: "fs.rm", reason: "deletes")])
        let json = try RobotJSON.encode(report.robot)
        #expect(json.contains("\"schema\":\"rv.check.v1\"") || json.contains("\"schema\" : \"rv.check.v1\""))
        #expect(json.contains("would_stop"))
    }

    @Test("checking a real plan in an empty home leaves the home as it was, apart from peek's judge log")
    func readOnly() async throws {
        let home = try isolatedHome()
        let before = try EverydayFiles.snapshot(home)
        let report = await CheckRun.report(
            steps: ["ls", "rm -rf /"],
            cwd: WorkingDirectory(validating: home.path),
            home: home
        )
        #expect(report.steps.count == 2)
        #expect(report.steps[0].outcome == .fine)
        #expect(report.steps[1].outcome.needsPerson)
        let changed = try EverydayFiles.snapshot(home).subtracting(before)
        #expect(changed.allSatisfy { $0.contains("judge-log") || $0.hasSuffix("/") }, "\(changed)")
    }
}

// MARK: - rv prompt

@Suite("rv prompt")
struct PromptCommandTests {
    @Test("down beats needs-you beats off beats watching beats unknown beats guarding")
    func priority() {
        #expect(PromptState(rvd: .down, posture: .off([.claude]), waiting: [.claude], watchedToday: 3) == .down)
        #expect(PromptState(rvd: .unknown, posture: .off([.claude]), waiting: [.claude], watchedToday: 3)
            == .needsYou(count: 1, host: .claude))
        #expect(PromptState(rvd: .up, posture: .guarding, waiting: [.claude, .grok], watchedToday: 0)
            == .needsYou(count: 2, host: nil))
        #expect(PromptState(rvd: .up, posture: .guarding, waiting: [.claude, .claude], watchedToday: 0)
            == .needsYou(count: 2, host: .claude))
        #expect(PromptState(rvd: .unknown, posture: .off([.claude]), waiting: [], watchedToday: 0)
            == .off(count: 1, host: .claude))
        #expect(PromptState(rvd: .up, posture: .off([.claude, .grok]), waiting: [], watchedToday: 0)
            == .off(count: 2, host: nil))
        #expect(PromptState(rvd: .unknown, posture: .watching, waiting: [], watchedToday: 3) == .watching(today: 3))
        #expect(PromptState(rvd: .up, posture: .watching, waiting: [], watchedToday: 3) == .watching(today: 3))
        #expect(PromptState(rvd: .unknown, posture: .guarding, waiting: [], watchedToday: 0) == .unknown)
        #expect(PromptState(rvd: .up, posture: .guarding, waiting: [], watchedToday: 0) == .guarding)
    }

    @Test("off when any host is off; else watching when any host or the machine observes")
    func posture() {
        #expect(PromptPosture(config: GuardConfig()) == .guarding)
        #expect(PromptPosture(config: GuardConfig(hosts: [.claude: .observe])) == .watching)
        #expect(PromptPosture(config: GuardConfig(mode: .observe)) == .watching)
        #expect(PromptPosture(config: GuardConfig(hosts: [.claude: .off])) == .off([.claude]))
        #expect(PromptPosture(config: GuardConfig(mode: .observe, hosts: [.grok: .off, .claude: .off]))
            == .off([.claude, .grok]))
    }

    @Test("an off host is never shown as ◆: it takes the stop glyph and stop ink")
    func offIsNeverGuarding() {
        #expect(PromptSegment.text(.off(count: 1, host: .claude), shell: nil, depth: .none) == "✕ claude off")
        #expect(PromptSegment.text(.off(count: 2, host: nil), shell: nil, depth: .none) == "✕ 2 off")
        let off = PromptSegment.text(.off(count: 1, host: .claude), shell: .zsh, depth: .ansi16)
        let down = PromptSegment.text(.down, shell: .zsh, depth: .ansi16)
        #expect(off.prefix(while: { $0 != "✕" }) == down.prefix(while: { $0 != "✕" }))
    }

    @Test("plain segments", arguments: [
        (PromptState.guarding, "◆"),
        (.unknown, "◆?"),
        (.watching(today: 0), "◐"),
        (.watching(today: 2), "◐ 2"),
        (.needsYou(count: 1, host: .claude), "⏺ claude waiting"),
        (.needsYou(count: 2, host: nil), "⏺ 2 waiting"),
        (.down, "✕ rv down"),
    ])
    func plain(state: PromptState, expected: String) {
        #expect(PromptSegment.text(state, shell: nil, depth: .truecolor) == expected)
    }

    @Test("zsh and bash wrap the escapes so the line editor counts only the glyph")
    func shells() {
        let zsh = PromptSegment.text(.down, shell: .zsh, depth: .ansi16)
        #expect(zsh.hasPrefix("%{\u{1B}[") && zsh.hasSuffix("%{\u{1B}[0m%}"))
        #expect(zsh.contains("%}✕ rv down%{"))
        let bash = PromptSegment.text(.down, shell: .bash, depth: .ansi16)
        #expect(bash.hasPrefix("\\[\u{1B}[") && bash.contains("\\]✕ rv down\\["))
        #expect(PromptSegment.text(.down, shell: .zsh, depth: .none) == "✕ rv down")
    }

    @Test("hello only: up, down and slow, and send is never called")
    func helloOnly() async {
        // A budget no instant fake can miss, even on a starved test pool:
        // this test is about how answers read, the budget test about time.
        let budget = 20_000
        let up = HelloOnlyTransport(reply: .answer(ProtocolVersion.name))
        #expect(await PromptRun.hello(over: up, budgetMs: budget) == .up)
        let wrong = HelloOnlyTransport(reply: .answer("other.v1"))
        #expect(await PromptRun.hello(over: wrong, budgetMs: budget) == .down)
        let refused = HelloOnlyTransport(reply: .fail(.connectFailed))
        #expect(await PromptRun.hello(over: refused, budgetMs: budget) == .down)
        let timedOut = HelloOnlyTransport(reply: .fail(.timeout))
        #expect(await PromptRun.hello(over: timedOut, budgetMs: budget) == .unknown)
        #expect(await PromptRun.hello(over: nil, budgetMs: budget) == .down)
        for transport in [up, wrong, refused, timedOut] {
            #expect(transport.sends == 0)
            #expect(transport.hellos == 1)
        }
    }

    @Test("a hello that never answers gives up at the budget")
    func budget() async {
        // The hello hangs until the test releases it, so an answer while it
        // is still held proves the budget won, with no wall-clock bound a
        // loaded run could miss. The release binary's timing is in H5.md.
        let stuck = HelloOnlyTransport(reply: .hang)
        let liveness = await PromptRun.hello(over: stuck, budgetMs: 30)
        #expect(liveness == .unknown)
        #expect(stuck.hangEnded == false)
        stuck.release()
        #expect(stuck.sends == 0)
    }

    @Test("an empty home reads as guarding and writes nothing")
    func readOnly() async throws {
        let home = try isolatedHome()
        let before = try EverydayFiles.snapshot(home)
        let state = await PromptRun.state(home: home, liveness: { .up })
        #expect(state == .guarding)
        #expect(try EverydayFiles.snapshot(home) == before)
    }
}

// MARK: - rv news

@Suite("rv news")
struct NewsCommandTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func decision(_ verdict: DecisionVerdict, _ host: HookHost, ago: TimeInterval) -> DecisionRecord {
        DecisionRecord(time: now.addingTimeInterval(-ago), verdict: verdict, host: .hook(host), tool: .bash, command: "ls")
    }

    @Test("counts the week, the refusals and the busiest host")
    func week() {
        let week = NewsWeek(decisions: [
            Self.decision(.allowed, .claude, ago: 60),
            Self.decision(.allowed, .claude, ago: 120),
            Self.decision(.refused, .claude, ago: 180),
            Self.decision(.denied, .grok, ago: 240),
        ], stopped: 1, watched: 2)
        #expect(week == NewsWeek(checked: 4, refused: 1, stopped: 1, watched: 2, busiest: .init(host: "claude", percent: 75)))
        #expect(NewsWeek(decisions: nil, stopped: 0, watched: 0).checked == nil)
        #expect(NewsWeek(decisions: [], stopped: 0, watched: 0).busiest == nil)
    }

    @Test("reads only the last seven days of the decision log")
    func readsLog() throws {
        let home = try isolatedHome()
        let config = RVPolicyPaths.configDirectory(home: home)
        let log = DecisionLog(configDirectory: config)
        log.append(Self.decision(.allowed, .claude, ago: 60), now: Self.now, prunes: false)
        log.append(Self.decision(.allowed, .claude, ago: 8 * 24 * 60 * 60), now: Self.now, prunes: false)
        let week = NewsWeek.read(configDirectory: config, now: Self.now)
        #expect(week.checked == 1)
    }

    @Test("an empty home says there is no decision log, and writes nothing")
    func readOnly() throws {
        let home = try isolatedHome()
        let before = try EverydayFiles.snapshot(home)
        let week = NewsWeek.read(configDirectory: RVPolicyPaths.configDirectory(home: home), now: Self.now)
        #expect(week.checked == nil)
        let text = NewsReport(version: "0.2.2", week: week, notes: []).text
        #expect(text.contains("no decision log here"))
        #expect(try EverydayFiles.snapshot(home) == before)
    }

    @Test("text shows the week and measures a note on it")
    func text() {
        let report = NewsReport(
            version: "9.9.9",
            week: NewsWeek(checked: 1204, refused: 0, stopped: 3, watched: 7, busiest: .init(host: "claude", percent: 80)),
            notes: [ReleaseNote("Watch mode keeps a record", measure: .watched), ReleaseNote("Plain note")]
        )
        let text = report.text
        #expect(text.hasPrefix("◆ rv 9.9.9 · your last 7 days\n"))
        #expect(text.contains("  checked   1,204 commands · 3 stopped · 7 watched"))
        #expect(text.contains("  busiest   claude 80%"))
        #expect(text.contains("  ◆ Watch mode keeps a record · 7 this week"))
        #expect(text.contains("  ◆ Plain note\n"))
        #expect(text.contains("refused") == false)
        #expect(text.contains("→ rv blocks"))
    }

    @Test("numbers group the same on every locale")
    func number() {
        #expect(NewsReport.number(0) == "0")
        #expect(NewsReport.number(999) == "999")
        #expect(NewsReport.number(1000) == "1,000")
        #expect(NewsReport.number(1_234_567) == "1,234,567")
    }

    @Test("this build has notes for its own version")
    func notesForThisVersion() {
        #expect(ReleaseNotes.notes(for: ProductVersion.semver).isEmpty == false)
    }

    @Test("robot JSON is rv.news.v1")
    func robot() throws {
        let json = try RobotJSON.encode(NewsReport(version: "1", week: NewsWeek(checked: nil, refused: 0, stopped: 0, watched: 0), notes: []).robot)
        #expect(json.contains("rv.news.v1"))
        #expect(json.contains("window_days"))
        #expect(json.contains("busiest"))
    }

    @Test("robot JSON names the busiest host")
    func robotBusiest() throws {
        let week = NewsWeek(checked: 4, refused: 0, stopped: 0, watched: 0, busiest: .init(host: "claude", percent: 75))
        let data = Data(try RobotJSON.encode(NewsReport(version: "1", week: week, notes: []).robot).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let busiest = try #require(object["busiest"] as? [String: Any])
        #expect(busiest["host"] as? String == "claude")
        #expect(busiest["percent"] as? Int == 75)
    }
}

// MARK: - Helpers

/// Every file under a home with its size and modification time, so a test
/// can prove a command changed nothing.
enum EverydayFiles {
    static func snapshot(_ home: HomeDirectory) throws -> Set<String> {
        let root = URL(fileURLWithPath: home.path)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        ) else { return [] }
        var entries = Set<String>()
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let relative = String(url.path.dropFirst(root.path.count))
            if values.isDirectory == true {
                entries.insert(relative + "/")
            } else {
                let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                entries.insert("\(relative) \(values.fileSize ?? 0) \(stamp)")
            }
        }
        return entries
    }
}

/// A transport that answers hello one way and records every call. `send`
/// is a write path the prompt must never take.
final class HelloOnlyTransport: ServiceTransport {
    enum Reply: Sendable {
        case answer(String)
        case fail(ServiceTransportError)
        case hang
    }

    struct HangState {
        var waiting: CheckedContinuation<Void, Never>?
        var released = false
        var ended = false
    }

    let reply: Reply
    private let helloCalls = Mutex(0)
    private let sendCalls = Mutex(0)
    private let hang = Mutex(HangState())

    init(reply: Reply) {
        self.reply = reply
    }

    var hellos: Int { helloCalls.withLock { $0 } }
    var sends: Int { sendCalls.withLock { $0 } }

    var oneShotEvaluateTimeoutMs: Int { 700 }

    func hello(clientSemver: String) async throws -> HelloAckView {
        try await helloHookConsult(clientSemver: clientSemver)
    }

    func helloHookConsult(clientSemver: String) async throws -> HelloAckView {
        helloCalls.withLock { $0 += 1 }
        switch reply {
        case .answer(let name):
            return HelloAckView(protocolName: name, serviceSemver: ProtocolVersion.serviceSemver, status: .ok)
        case .fail(let error):
            throw error
        case .hang:
            await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
                let resumeNow = hang.withLock { state -> Bool in
                    if state.released { return true }
                    state.waiting = waiting
                    return false
                }
                if resumeNow { waiting.resume() }
            }
            hang.withLock { $0.ended = true }
            throw ServiceTransportError.timeout
        }
    }

    /// True once a `.hang` hello has returned.
    var hangEnded: Bool { hang.withLock { $0.ended } }

    /// Lets a `.hang` hello return, now or as soon as it starts.
    func release() {
        let waiting = hang.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }

    func send(_ body: Data) async throws -> Data {
        sendCalls.withLock { $0 += 1 }
        throw ServiceTransportError.connectFailed
    }

    func sendHookConsult(_ body: Data, timeoutMs: Int) async throws -> Data {
        try await send(body)
    }

    func invalidate() {}
}
