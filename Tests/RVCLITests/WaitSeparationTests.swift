import Foundation
import RVDomain
import RVIPC
import RVPolicy
import Testing
@testable import RVCLI

/// `rv wait` can wait; it can never decide. The agent runs it, so nothing
/// it does may unlock, resolve, mint or prompt: these tests hold that
/// from three sides (what it sends rvd, what it does to the ledger, and
/// what its source can call).
@Suite("rv wait has no approve path")
struct WaitSeparationTests {
    private let ack = HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the only call rv wait sends rvd is events")
    func sendsOnlyEvents() async throws {
        let transport = ScriptedTransport(
            ack: ack, responseResult: .events(EventsReply(stream: UUID(), cursor: 1, events: [])))
        let client = ServiceClient(transport: transport, allowOnceDirectory: try temporaryDirectory(), home: nil)
        let ledger = ScriptedLedger([[WaitCommandTests.row(.pending)], [WaitCommandTests.row(.pending)],
                                     [WaitCommandTests.row(.pending)], [WaitCommandTests.row(.granted)]])
        var run = WaitRun(ledger: ledger, events: LiveWaitEvents(client: client), limit: .seconds(100))
        run.sleep = { _ in }
        let (ending, _) = await run.wait(for: WaitCommandTests.code)
        #expect(ending == .finished(.unlocked(.code)))
        #expect(transport.sendCount == 2)
        for body in transport.sends {
            let request = try IPCJSON.decode(IPCRequest.self, from: body)
            guard case .events = request.method else {
                Issue.record("rv wait sent \(request.method), not events")
                continue
            }
        }
    }

    @Test("waiting never spends or changes the code: the owner can still redeem it after")
    func ledgerIsUntouched() async throws {
        let directory = try temporaryDirectory()
        let store = AllowOnceStore(baseDirectory: directory)
        let now = Date()
        let owner = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let minted = try await store.mint(
            matchingView: MatchingView(rawValue: "git reset --hard"), cwd: try #require(WorkingDirectory(validating: "/tmp/app")),
            ruleID: nil, tty: owner, now: now)
        let file = RVPolicyPaths.allowOnceFile(inConfigDir: directory)
        let before = try Data(contentsOf: file)

        var run = WaitRun(ledger: LiveWaitLedger(store: store), events: UnavailableEvents(), limit: .milliseconds(30))
        run.sleep = { _ in try? await Task.sleep(for: .milliseconds(10)) }
        let (ending, _) = await run.wait(for: try #require(WaitCode(minted.rawValue)))

        #expect(ending == .stillWaiting)
        #expect(try Data(contentsOf: file) == before)
        #expect(await store.validatePending(code: minted.rawValue, now: now) != nil)
    }

    @Test("an agent without a terminal can wait, and the unlock it waits for still needs one")
    func agentWaitsOwnerDecides() async throws {
        let directory = try temporaryDirectory()
        let store = AllowOnceStore(baseDirectory: directory)
        let now = Date()
        let owner = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let agent = TTYCapability(stdinIsTTY: false, stdoutIsTTY: false, ci: false)
        let minted = try await store.mint(
            matchingView: MatchingView(rawValue: "git reset --hard"), cwd: try #require(WorkingDirectory(validating: "/tmp/app")),
            ruleID: nil, tty: owner, now: now)
        await #expect(throws: AllowOnceError.ttyRequired) {
            _ = try await store.redeem(code: minted.rawValue, tty: agent, now: now)
        }
        // rv wait itself takes no terminal and no owner proof: it parses
        // and validates with none.
        let parsed = try RV.parseAsRoot(["wait", minted.rawValue])
        #expect(parsed is Wait)
    }

    /// Calls that decide, prompt or write. None may appear in rv wait's
    /// code (comments aside).
    static let forbidden = [
        "redeem", "attestTTYRedemption", "confirmOwnerAction", "mintAllowOnce", "mint(", "pendingResolve",
        "PendingResolve", "ruleSave", "setPackEnabled", ".clear(", "project(", "OwnerConfirmation",
        "CLIOwnerAuth", "hookEvaluate", "evaluate(",
    ]

    @Test("rv wait's source names no call that decides, prompts or writes")
    func sourceHasNoApproveCall() throws {
        let commands = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RVCLI/Commands")
        var hits: [String] = []
        for name in ["WaitCommand.swift", "WaitWatch.swift"] {
            let text = try String(contentsOf: commands.appendingPathComponent(name), encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for word in Self.forbidden where code.contains(word) {
                    hits.append("\(name):\(number + 1): \(word)")
                }
            }
        }
        #expect(hits.isEmpty, "rv wait reaches a deciding call:\n\(hits.joined(separator: "\n"))")
    }
}
