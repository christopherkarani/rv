#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVCLI
@testable import RVService

/// F2 end to end in one process: the CLI's commands against a real
/// `ServiceRuntime` (rvd's dispatch, store, owner check and appliers), with
/// rvd's owner prompt played by a test double. Nothing reaches a live rvd.
@Suite("rv proposals")
struct ProposalsCommandTests {
    final class Prompt: OwnerAuthenticating, @unchecked Sendable {
        let approve: Bool
        let reasons = Mutex<[String]>([])
        init(approve: Bool) { self.approve = approve }
        func authenticate(reason: String) async -> Bool {
            reasons.withLock { $0.append(reason) }
            return approve
        }
        var shown: [String] { reasons.withLock { $0 } }
    }

    final class NoPassword: OwnerPasswordChecking, @unchecked Sendable {
        func check(_ password: String) async -> Bool? { false }
    }

    /// The CLI's view of rvd: each call goes through `dispatch` as a
    /// same-user socket peer, the way an agent's `rv` reaches it.
    struct Rvd: ProposalServicing {
        let runtime: ServiceRuntime

        func call<T>(_ method: IPCMethod, _ pick: (IPCResult) -> T?) async -> Result<T, ServiceClient.ServiceCommandError> {
            let id = UUID()
            // The genuine rv CLI (pinned `.cli`), as rvd sees it on macOS.
            let code = PeerCodeIdentity(identifier: "dev.rv.cli", teamIdentifier: "TEAM", cdHash: Data([1]),
                executablePath: "/usr/local/bin/rv", isAdHoc: false, hardenedRuntime: true, injectionExceptions: [])
            let context = AuthenticatedRequestContext.captured(
                peer: AuthenticatedPeer(
                    evidence: PlatformPeerEvidence(processID: 77, effectiveUserID: UInt32(geteuid()), auditToken: Data([7]),
                        codeIdentity: code, componentRole: .cli),
                    connectionID: id),
                connectionID: id)
            let result = await runtime.dispatch(IPCRequest(method: method), context: context).result
            guard let reply = pick(result) else { return .failure(.service("\(result)")) }
            return .success(reply)
        }
        func proposeLoosen(_ params: ProposeLoosenParams) async -> Result<ProposeLoosenReply, ServiceClient.ServiceCommandError> {
            await call(.proposeLoosen(params), ProposeLoosenCall.extract)
        }
        func listProposals(_ params: ListProposalsParams) async -> Result<ListProposalsReply, ServiceClient.ServiceCommandError> {
            await call(.listProposals(params), ListProposalsCall.extract)
        }
        func decideProposal(_ params: DecideProposalParams) async -> Result<DecideProposalReply, ServiceClient.ServiceCommandError> {
            await call(.decideProposal(params), DecideProposalCall.extract)
        }
    }

    struct Fixture {
        let home: HomeDirectory
        let rvd: Rvd
        let prompt: Prompt
        var config: URL { RVPolicyPaths.configDirectory(home: home) }
    }

    static func fixture(approve: Bool = true) throws -> Fixture {
        let home = try isolatedHome()
        let prompt = Prompt(approve: approve)
        let allowOnce = FileManager.default.temporaryDirectory.appendingPathComponent("rv-ao-\(UUID().uuidString)")
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: nil, allowOnceDirectory: allowOnce,
            idleExitSeconds: IdleWatchdog.defaultSeconds, log: nil, analytics: nil, clock: { Date() },
            pendingApprovals: .automatic, ceremonies: WorkspaceOperatorCeremonyService(),
            ownerPresence: OwnerPresence(checker: NoPassword(), authenticator: prompt))
        return Fixture(home: home, rvd: Rvd(runtime: runtime), prompt: prompt)
    }

    /// `body` as `rv` under an agent (no terminal) or the owner (a terminal).
    /// The owner seam is never set: only rvd's check can approve.
    static func run(
        _ fixture: Fixture, terminal: Bool, environment: [String: String] = ["CLAUDECODE": "1"],
        _ body: () async throws -> Void
    ) async throws -> (stdout: String, stderr: String, exit: Int32) {
        let out = CLIOutputCapture()
        var context = CLIProcess.Context(
            home: fixture.home, environment: environment, stdinIsTTY: terminal, stdoutIsTTY: terminal,
            workspacePath: fixture.home.rawValue + "/code/app", output: out.sink)
        context.proposalService = fixture.rvd
        var exit: Int32 = 0
        do {
            try await CLIProcess.$context.withValue(context) { try await body() }
        } catch let code as ExitCode {
            exit = code.rawValue
        }
        return (out.stdout, out.stderr, exit)
    }

    static func allowlist(_ fixture: Fixture) -> AllowlistStore.LoadResult {
        AllowlistStore(baseDirectory: fixture.config).loadForValidate(workspacePath: nil)
    }

    // MARK: an agent asks

    @Test func anAgentsExceptionIsSentAsAProposalAndChangesNothing() async throws {
        let fixture = try Self.fixture()
        let result = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing the release branch"])
            try await command.run()
        }
        let owner = ProposalText.ownerName
        #expect(result.exit == 0)
        #expect(result.stdout == """
            ◆ Sent to \(owner) as proposal p-1. An exception is looser.
              \(owner) decides with \(ProposalText.how). Nothing changes until then. Don't retry.
            → rv proposals p-1

            """)
        #expect(result.stderr.isEmpty)
        #expect(fixture.prompt.shown.isEmpty, "an agent's loosen never raises the owner's prompt")
        #expect(Self.allowlist(fixture) == .missing)
    }

    /// `--propose` is a proposal even on a terminal (an agent's pty): the
    /// form the self-protection guard lets an agent run never prompts.
    @Test func proposeIsAProposalEvenOnATerminal() async throws {
        let fixture = try Self.fixture()
        let result = try await Self.run(fixture, terminal: true) {
            var command = try AllowlistAddCommand.parse(["git reset --hard", "--reason", "rebasing", "--propose"])
            try await command.run()
        }
        #expect(result.exit == 0)
        #expect(result.stdout.hasPrefix("◆ Sent to \(ProposalText.ownerName) as proposal p-1. An exception is looser.\n"))
        #expect(fixture.prompt.shown.isEmpty)
        #expect(Self.allowlist(fixture) == .missing)
    }

    @Test func askingTwiceSaysItWasAlreadySent() async throws {
        let fixture = try Self.fixture()
        for _ in 0..<2 {
            _ = try await Self.run(fixture, terminal: false) {
                var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
                try await command.run()
            }
        }
        let again = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        #expect(again.stdout.hasPrefix("◆ Already sent to \(ProposalText.ownerName) as proposal p-1."))
    }

    @Test func anAgentsSafetyNormalIsAProposalAndStrictStays() async throws {
        let fixture = try Self.fixture()
        try SafetyStore(configDirectory: fixture.config).saveMachine(.strict)
        let result = try await Self.run(fixture, terminal: false) {
            try await Safety.parse(["normal"]).run()
        }
        #expect(result.exit == 0)
        #expect(result.stdout.contains("as proposal p-1. Normal safety is looser than strict."))
        #expect(SafetyStore(configDirectory: fixture.config).loadMachine() == .strict)
    }

    @Test func anAgentCannotApproveOrDecline() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        let approve = try await Self.run(fixture, terminal: false) {
            var command = try ProposalsApprove.parse(["p-1"])
            try await command.run()
        }
        #expect(approve.exit == 2)
        #expect(approve.stderr == "rv proposals approve: requires an interactive TTY (stdin and stdout): rv takes this only from a person at a terminal, so an agent cannot approve itself. Run it in your own Terminal\n")
        let reject = try await Self.run(fixture, terminal: false) {
            var command = try ProposalsReject.parse(["p-1"])
            try await command.run()
        }
        #expect(reject.exit == 2)
        #expect(fixture.prompt.shown.isEmpty)
        #expect(Self.allowlist(fixture) == .missing)
    }

    @Test func anAgentCanReadProposals() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing the release branch"])
            try await command.run()
        }
        let listed = try await Self.run(fixture, terminal: false) {
            var command = try ProposalsList.parse([])
            try await command.run()
        }
        #expect(listed.exit == 0)
        #expect(listed.stdout == """
            ◆ rv  1 proposal waits for you

              p-1  ◐ Looser: rule core.git:reset-hard is allowed (an allowlist exception)
                    from claude · ~/code/app · just now
                    claude says: rebasing the release branch

            → rv proposals approve p-1

            """)
    }

    // MARK: pack off (G6's packsOffAuthorization gate)

    static func redisIsOn(_ fixture: Fixture) throws -> Bool {
        try PacksFacade.effectiveIDs(home: fixture.home).contains(PackID(rawValue: "database.redis"))
    }

    @Test func anAgentsPackOffIsAProposal_andTheOwnerApprovesIt() async throws {
        let fixture = try Self.fixture(approve: true)
        _ = try await Self.run(fixture, terminal: false) { try await Protect.parse(["redis"]).run() }
        #expect(try Self.redisIsOn(fixture))
        let filed = try await Self.run(fixture, terminal: false) {
            var command = try Packs.Disable.parse(["database.redis"])
            try await command.run()
        }
        #expect(filed.exit == 0)
        #expect(filed.stdout.contains("as proposal p-1. Turning a pack off is looser."))
        #expect(fixture.prompt.shown.isEmpty, "an agent's pack off never raises the owner's prompt")
        #expect(try Self.redisIsOn(fixture), "nothing changes until the owner approves")

        let approved = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsApprove.parse(["p-1"])
            try await command.run()
        }
        #expect(approved.exit == 0)
        #expect(approved.stdout.hasSuffix("✓ Approved p-1: pack database.redis is turned off\n"))
        #expect(fixture.prompt.shown.first?.hasPrefix("approve rv proposal p-1: pack database.redis is turned off") == true)
        #expect(try Self.redisIsOn(fixture) == false)
    }

    @Test func protectOffProposeIsAProposalEvenOnATerminal() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: true) { try await Protect.parse(["redis"]).run() }
        let filed = try await Self.run(fixture, terminal: true) {
            try await Protect.parse(["redis", "off", "--propose"]).run()
        }
        #expect(filed.exit == 0)
        #expect(filed.stdout.contains("as proposal p-1. Turning a pack off is looser."))
        #expect(fixture.prompt.shown.isEmpty)
        #expect(try Self.redisIsOn(fixture))
    }

    @Test func packsOffNamesEachPackAsItsOwnProposal() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try Packs.Enable.parse(["database.redis", "containers.docker"])
            try await command.run()
        }
        let filed = try await Self.run(fixture, terminal: false) {
            var command = try Packs.Disable.parse(["database.redis", "containers.docker"])
            try await command.run()
        }
        #expect(filed.exit == 0)
        #expect(filed.stdout.contains("proposal p-1."))
        #expect(filed.stdout.contains("proposal p-2."))
        let on = Set(try PacksFacade.effectiveIDs(home: fixture.home).map(\.rawValue))
        #expect(on.isSuperset(of: ["database.redis", "containers.docker"]))
    }

    /// Security review M1: a category is never one proposal for "pack
    /// backup". Each pack in it is its own proposal, by exact id, so the
    /// owner approves exactly what goes off.
    @Test func aCategoryOffIsOneProposalPerPackByExactID() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try Packs.Enable.parse(["backup"])
            try await command.run()
        }
        let filed = try await Self.run(fixture, terminal: false) {
            var command = try Packs.Disable.parse(["backup", "--propose"])
            try await command.run()
        }
        #expect(filed.exit == 0)
        let listed = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsList.parse([])
            try await command.run()
        }
        for pack in ["backup.borg", "backup.rclone", "backup.restic", "backup.velero"] {
            #expect(listed.stdout.contains("Looser: pack \(pack) is turned off"))
        }
        #expect(listed.stdout.contains("pack backup is turned off") == false)
    }

    // MARK: the owner decides

    @Test func theOwnerApprovesWithRvdsPromptAndRvdApplies() async throws {
        let fixture = try Self.fixture(approve: true)
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        let approved = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsApprove.parse(["p-1"])
            try await command.run()
        }
        #expect(approved.exit == 0)
        #expect(approved.stdout.hasSuffix(
            "✓ Approved p-1: rule core.git:reset-hard is allowed (an allowlist exception)\n"))
        #expect(approved.stdout.contains("fingerprint "))
        #expect(fixture.prompt.shown.count == 1)
        #expect(fixture.prompt.shown.first?.hasPrefix("approve rv proposal p-1: rule core.git:reset-hard is allowed") == true)
        guard case .ok(let entries) = Self.allowlist(fixture) else {
            Issue.record("the approved exception was not written")
            return
        }
        #expect(entries.count == 1)
    }

    @Test func aDeclinedPromptChangesNothing() async throws {
        let fixture = try Self.fixture(approve: false)
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        let refused = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsApprove.parse(["p-1"])
            try await command.run()
        }
        #expect(refused.exit == OwnerConfirmation.refusalExitCode)
        #expect(refused.stderr.hasSuffix(
            "rv: approving p-1 was not approved (the prompt was cancelled, failed or timed out)\n"))
        #expect(Self.allowlist(fixture) == .missing)
    }

    @Test func theOwnerDeclinesWithAReason() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        let declined = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsReject.parse(["p-1", "--reason", "rebase locally, push a new branch"])
            try await command.run()
        }
        #expect(declined.exit == 0)
        #expect(declined.stdout == "✓ Declined p-1. Nothing changed.\n")
        let shown = try await Self.run(fixture, terminal: false) {
            var command = try ProposalsList.parse(["p-1"])
            try await command.run()
        }
        #expect(shown.stdout.contains("        declined: rebase locally, push a new branch\n"))
        #expect(fixture.prompt.shown.isEmpty)
    }

    @Test func approvingSomethingAlreadyDecidedIsRefused() async throws {
        let fixture = try Self.fixture()
        _ = try await Self.run(fixture, terminal: false) {
            var command = try AllowlistAdd.parse(["core.git:reset-hard", "--reason", "rebasing"])
            try await command.run()
        }
        _ = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsReject.parse(["p-1"])
            try await command.run()
        }
        let late = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsApprove.parse(["p-1"])
            try await command.run()
        }
        #expect(late.exit == 1)
        #expect(late.stderr == "rv proposals approve: p-1 is already declined; nothing changed\n")
        #expect(fixture.prompt.shown.isEmpty)
    }

    @Test func aBadIDIsAUsageError() async throws {
        let fixture = try Self.fixture()
        let result = try await Self.run(fixture, terminal: true) {
            var command = try ProposalsApprove.parse(["21"])
            try await command.run()
        }
        #expect(result.exit == 2)
        #expect(result.stderr == "rv proposals approve: 21 is not a proposal id (like p-21)\n")
    }

    @Test func noProposalsSaysSo() async throws {
        let fixture = try Self.fixture()
        let result = try await Self.run(fixture, terminal: false) {
            var command = try ProposalsList.parse([])
            try await command.run()
        }
        #expect(result.stdout == "◆ rv  no proposals wait for you\n")
    }
}
