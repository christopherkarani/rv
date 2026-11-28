#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
import RVDomain
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService

/// F2: an agent's loosen is only ever a proposal. rvd applies one only
/// after the device owner approves that exact proposal at rvd's own owner
/// check (the real `OwnerPresence`, driven by its test doubles), and only
/// while its content still hashes to what the owner was shown.
@Suite("Loosen proposals in rvd")
struct LoosenProposalServiceTests {
    /// Stands in for rvd's LocalAuthentication prompt. `during` runs while
    /// the prompt is up: what another process does while the owner reads.
    final class Prompt: OwnerAuthenticating, @unchecked Sendable {
        let approve: Bool
        let during: @Sendable () -> Void
        let reasons = Mutex<[String]>([])
        init(approve: Bool, during: @escaping @Sendable () -> Void = {}) {
            self.approve = approve
            self.during = during
        }
        func authenticate(reason: String) async -> Bool {
            reasons.withLock { $0.append(reason) }
            during()
            return approve
        }
        var shown: [String] { reasons.withLock { $0 } }
    }

    final class Password: OwnerPasswordChecking, @unchecked Sendable {
        let accepted: String
        let calls = Mutex(0)
        init(accepted: String) { self.accepted = accepted }
        func check(_ password: String) async -> Bool? {
            calls.withLock { $0 += 1 }
            return password == accepted
        }
    }

    /// Records every change rvd applies.
    final class Applied: @unchecked Sendable {
        let changes = Mutex<[(PolicyLoosen, String)]>([])
        let fail: Bool
        init(fail: Bool = false) { self.fail = fail }
        var applier: LoosenApplier {
            LoosenApplier(problem: { _ in nil }, apply: { change, authorization in
                if self.fail { throw LoosenProposalError.invalid("disk full") }
                self.changes.withLock { $0.append((change, authorization)) }
            })
        }
        var count: Int { changes.withLock { $0.count } }
    }

    struct Fixture {
        let runtime: ServiceRuntime
        let home: HomeDirectory
        var configDirectory: URL { RVPolicyPaths.configDirectory(home: home) }
        var store: LoosenProposalStore { LoosenProposalStore(configDirectory: configDirectory) }
    }

    static func fixture(
        prompt: Prompt? = nil, password: Password = Password(accepted: "secret"), applier: LoosenApplier? = nil
    ) throws -> Fixture {
        let home = try #require(HomeDirectory(validating: try isolatedHomeDirectory().path))
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(), idleExitSeconds: IdleWatchdog.defaultSeconds,
            log: nil, analytics: nil, clock: { Date() }, pendingApprovals: .automatic,
            ceremonies: WorkspaceOperatorCeremonyService(),
            ownerPresence: OwnerPresence(checker: password, authenticator: prompt),
            loosenApplier: applier)
        return Fixture(runtime: runtime, home: home)
    }

    /// A same-user socket peer: what an agent's `rv` (or any process the
    /// agent starts) is to rvd.
    static func agent() -> AuthenticatedRequestContext {
        let id = UUID()
        return .captured(
            peer: .socketPeer(processID: 4242, effectiveUserID: UInt32(geteuid()), connectionID: id), connectionID: id)
    }

    /// The pinned rv CLI, running as rvd's user: the only caller that may
    /// decide where rvd shows its own prompt.
    static func cli() -> AuthenticatedRequestContext {
        let code = PeerCodeIdentity(identifier: "dev.rv.cli", teamIdentifier: "TEAM", cdHash: Data([1]),
            executablePath: "/usr/local/bin/rv", isAdHoc: false, hardenedRuntime: true, injectionExceptions: [])
        let id = UUID()
        return .captured(
            peer: AuthenticatedPeer(
                evidence: PlatformPeerEvidence(processID: 7, effectiveUserID: UInt32(geteuid()), auditToken: Data([7]),
                    codeIdentity: code, componentRole: .cli),
                connectionID: id),
            connectionID: id)
    }

    static let change = PolicyLoosen.allowRule(rule: "core.git:reset-hard", reason: "rebasing the release branch")

    static func call(_ runtime: ServiceRuntime, _ method: IPCMethod,
                     context: AuthenticatedRequestContext = agent()) async -> IPCResult {
        await runtime.dispatch(IPCRequest(method: method), context: context).result
    }

    static func propose(_ runtime: ServiceRuntime, _ change: PolicyLoosen = change) async throws -> ProposalItem {
        let result = await call(runtime, .proposeLoosen(ProposeLoosenParams(
            change: change, from: "claude", cwd: "~/code/app", clientSemver: ProtocolVersion.serviceSemver)))
        guard case .proposeLoosen(let reply) = result else {
            Issue.record("unexpected \(result)")
            throw CancellationError()
        }
        return try #require(reply.proposal)
    }

    static func decide(
        _ runtime: ServiceRuntime, _ item: ProposalItem, _ decision: DecideProposalParams.Decision,
        hash: String? = nil, proof: OwnerProof? = nil, context: AuthenticatedRequestContext = cli()
    ) async -> DecideProposalReply? {
        let result = await call(runtime, .decideProposal(DecideProposalParams(
            id: item.id, contentHash: hash ?? item.contentHash, decision: decision, proof: proof,
            clientSemver: ProtocolVersion.serviceSemver)), context: context)
        guard case .decideProposal(let reply) = result else { return nil }
        return reply
    }

    // MARK: no agent path applies a loosen

    @Test func filingStoresAProposalAndAppliesNothing() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        #expect(item.id == ProposalID(rawValue: "p-1"))
        #expect(item.status == .pending)
        #expect(applied.count == 0)
        #expect(prompt.shown.isEmpty, "filing never raises the owner's prompt")
        #expect(FileManager.default.fileExists(
            atPath: RVPolicyPaths.allowlistFile(inConfigDir: fixture.configDirectory).path) == false)
    }

    @Test func theSameChangeTwiceIsOneProposal() async throws {
        let fixture = try Self.fixture()
        let first = try await Self.propose(fixture.runtime)
        let again = try await Self.propose(fixture.runtime)
        #expect(first.id == again.id)
        let listed = await Self.call(fixture.runtime, .listProposals(ListProposalsParams()))
        guard case .listProposals(let reply) = listed else { Issue.record("\(listed)"); return }
        #expect(reply.proposals.map(\.id) == [first.id])
    }

    @Test func declineAppliesNothingAndNeedsNoPrompt() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let reply = try #require(await Self.decide(fixture.runtime, item, .reject))
        #expect(reply.outcome == .rejected)
        #expect(reply.proposal?.status == .rejected)
        #expect(applied.count == 0)
        #expect(prompt.shown.isEmpty)
    }

    // MARK: security review M2 / L3

    /// Where rvd shows its own prompt, an agent's process cannot decide:
    /// it never picks the moment the owner's prompt appears.
    @Test func anAgentCannotApproveOrDeclineWhereRvdPrompts() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        for decision in [DecideProposalParams.Decision.approve, .reject] {
            let result = await Self.call(fixture.runtime, .decideProposal(DecideProposalParams(
                id: item.id, contentHash: item.contentHash, decision: decision,
                clientSemver: ProtocolVersion.serviceSemver)), context: Self.agent())
            #expect(result == .error(.authorizationDenied))
        }
        #expect(prompt.shown.isEmpty)
        #expect(applied.count == 0)
        #expect(try fixture.store.list(now: Date()).all.first?.status == .pending)
    }

    /// Where rvd checks a password, a decline needs it too.
    @Test func withoutRvdsPromptDecliningNeedsTheOwnersPassword() async throws {
        let fixture = try Self.fixture(prompt: nil, password: Password(accepted: "secret"), applier: Applied().applier)
        let item = try await Self.propose(fixture.runtime)
        let none = try #require(await Self.decide(fixture.runtime, item, .reject, context: Self.agent()))
        #expect(none.outcome == .ownerRefused)
        #expect(none.owner?.outcome == .proofRequired)
        #expect(try fixture.store.list(now: Date()).all.first?.status == .pending)
        let right = try #require(await Self.decide(
            fixture.runtime, item, .reject, proof: OwnerProof(password: "secret"), context: Self.agent()))
        #expect(right.outcome == .rejected)
    }

    /// One prompt per proposal, and not again right away.
    @Test func theOwnersPromptForOneProposalIsRateLimited() async throws {
        let prompt = Prompt(approve: false)
        let fixture = try Self.fixture(prompt: prompt, applier: Applied().applier)
        let item = try await Self.propose(fixture.runtime)
        #expect(await Self.decide(fixture.runtime, item, .approve)?.owner?.outcome == .declined)
        let again = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(again.outcome == .ownerRefused)
        #expect(again.owner?.outcome == .busy)
        #expect(prompt.shown.count == 1)
    }

    /// Rows carry full commands and paths: only rvd's own user reads them.
    @Test func anotherUserCannotFileListOrDecide() async throws {
        let fixture = try Self.fixture(applier: Applied().applier)
        let id = UUID()
        let stranger = AuthenticatedRequestContext.captured(
            peer: .socketPeer(processID: 99, effectiveUserID: UInt32(geteuid()) &+ 1, connectionID: id), connectionID: id)
        let listed = await Self.call(fixture.runtime, .listProposals(ListProposalsParams()), context: stranger)
        #expect(listed == .error(.authorizationDenied))
        let filed = await Self.call(fixture.runtime, .proposeLoosen(ProposeLoosenParams(
            change: Self.change, from: nil, cwd: nil, clientSemver: ProtocolVersion.serviceSemver)), context: stranger)
        #expect(filed == .error(.authorizationDenied))
    }

    /// A change too long for the prompt is shown from its start, marked
    /// cut, with the fingerprint; never "shown in your terminal".
    @Test func aLongCommandIsShownFromItsStartWithTheFingerprint() throws {
        let command = "echo " + String(repeating: "a", count: 900)
        let record = LoosenProposal(
            id: ProposalID(number: 3), change: .allowCommand(command: command, reason: "r"), from: nil, cwd: nil,
            createdAt: Date(),
            contentHash: LoosenProposalLedger.contentHash(
                id: ProposalID(number: 3), change: .allowCommand(command: command, reason: "r"), from: nil, cwd: nil))
        let prompt = LoosenProposalService.prompt(for: record)
        #expect(prompt.unicodeScalars.count <= ConfirmOwnerActionParams.maxSummaryBytes)
        #expect(prompt.hasPrefix("approve rv proposal p-3: the exact command "))
        #expect(prompt.contains("echo aaaa"))
        #expect(prompt.contains("… (cut; rv proposals p-3 shows all of it)"))
        #expect(prompt.hasSuffix("[\(record.fingerprint)]"))
        #expect(prompt.contains("shown in your terminal") == false)
    }

    @Test func anUnauthenticatedCallerCannotFileListOrDecide() async throws {
        let fixture = try Self.fixture()
        let filed = await Self.call(fixture.runtime, .proposeLoosen(ProposeLoosenParams(
            change: Self.change, from: nil, cwd: nil, clientSemver: ProtocolVersion.serviceSemver)),
            context: .unauthenticated)
        #expect(filed == .error(.authorizationDenied))
        let listed = await Self.call(fixture.runtime, .listProposals(ListProposalsParams()), context: .unauthenticated)
        #expect(listed == .error(.authorizationDenied))
    }

    @Test func aMalformedChangeIsRefusedBeforeAnythingIsStored() async throws {
        let fixture = try Self.fixture(applier: Applied().applier)
        let result = await Self.call(fixture.runtime, .proposeLoosen(ProposeLoosenParams(
            change: .allowRule(rule: "core.git:reset-hard", reason: "  "), from: nil, cwd: nil,
            clientSemver: ProtocolVersion.serviceSemver)))
        guard case .proposeLoosen(let reply) = result else { Issue.record("\(result)"); return }
        #expect(reply.outcome == .invalid)
        #expect(reply.problem == "a reason is required")
        #expect(try fixture.store.list(now: Date()).all.isEmpty)
    }

    // MARK: approving needs the owner

    @Test func approvingRunsRvdsOwnPromptWithRvsWordsThenApplies() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(reply.outcome == .approved)
        #expect(reply.proposal?.status == .approved)
        #expect(prompt.shown == [
            "approve rv proposal p-1: rule core.git:reset-hard is allowed (an allowlist exception) [\(item.contentHash.prefix(12))]",
        ])
        #expect(prompt.shown.first?.contains("rebasing") == false, "the agent's words never reach the prompt")
        let changes = applied.changes.withLock { $0 }
        #expect(changes.map(\.0) == [Self.change])
        #expect(changes.first?.1 == "owner (Touch ID or password at rvd's prompt), proposal p-1")
    }

    @Test func aDeclinedPromptAppliesNothingAndLeavesItWaiting() async throws {
        let applied = Applied()
        let fixture = try Self.fixture(prompt: Prompt(approve: false), applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(reply.outcome == .ownerRefused)
        #expect(reply.owner?.outcome == .declined)
        #expect(applied.count == 0)
        #expect(try fixture.store.list(now: Date()).all.first?.status == .pending)
    }

    @Test func withoutRvdsPromptApprovingNeedsTheOwnersPassword() async throws {
        let applied = Applied()
        let password = Password(accepted: "secret")
        let fixture = try Self.fixture(prompt: nil, password: password, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)

        let none = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(none.outcome == .ownerRefused)
        #expect(none.owner?.outcome == .proofRequired)
        let wrong = try #require(await Self.decide(fixture.runtime, item, .approve, proof: OwnerProof(password: "guess")))
        #expect(wrong.outcome == .ownerRefused)
        #expect(wrong.owner?.outcome == .wrongPassword)
        #expect(applied.count == 0)

        let right = try #require(await Self.decide(fixture.runtime, item, .approve, proof: OwnerProof(password: "secret")))
        #expect(right.outcome == .approved)
        #expect(right.owner?.presence == .password)
        #expect(applied.count == 1)
    }

    @Test func anUnauthenticatedApprovalNeverPromptsOrApplies() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let result = await Self.call(fixture.runtime, .decideProposal(DecideProposalParams(
            id: item.id, contentHash: item.contentHash, decision: .approve,
            clientSemver: ProtocolVersion.serviceSemver)), context: .unauthenticated)
        #expect(result == .error(.authorizationDenied))
        #expect(prompt.shown.isEmpty)
        #expect(applied.count == 0)
    }

    // MARK: approve what was shown

    @Test func aHashThatIsNotTheProposalsIsRefusedBeforeAnyPrompt() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let other = String(repeating: "0", count: 64)
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve, hash: other))
        #expect(reply.outcome == .changed)
        #expect(prompt.shown.isEmpty)
        #expect(applied.count == 0)
    }

    @Test func aProposalEditedOnDiskCanNeverBeApproved() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        try Self.rewrite(fixture) { $0.change = .allowRule(rule: "core.rm:rm-rf-root", reason: "rebasing the release branch") }
        // The shown hash and the edited row's own hash both fail.
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(reply.outcome == .changed)
        #expect(prompt.shown.isEmpty)
        #expect(applied.count == 0)
    }

    @Test func aProposalChangedWhileTheOwnerReadsThePromptIsNotApplied() async throws {
        let applied = Applied()
        let holder = Mutex<Fixture?>(nil)
        let prompt = Prompt(approve: true, during: {
            guard let fixture = holder.withLock({ $0 }) else { return }
            try? Self.rewrite(fixture) {
                $0.change = .allowCommand(command: "rm -rf ~", reason: "rebasing the release branch")
                $0.contentHash = $0.currentHash
            }
        })
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        holder.withLock { $0 = fixture }
        let item = try await Self.propose(fixture.runtime)
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(prompt.shown.count == 1)
        #expect(reply.outcome == .changed)
        #expect(applied.count == 0)
    }

    @Test func anApprovalCannotBeReplayed() async throws {
        let applied = Applied()
        let prompt = Prompt(approve: true)
        let fixture = try Self.fixture(prompt: prompt, applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        #expect(await Self.decide(fixture.runtime, item, .approve)?.outcome == .approved)
        let again = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(again.outcome == .notPending)
        #expect(prompt.shown.count == 1)
        #expect(applied.count == 1)
    }

    @Test func aFailedApplyLeavesTheProposalWaiting() async throws {
        let applied = Applied(fail: true)
        let fixture = try Self.fixture(prompt: Prompt(approve: true), applier: applied.applier)
        let item = try await Self.propose(fixture.runtime)
        let reply = try #require(await Self.decide(fixture.runtime, item, .approve))
        #expect(reply.outcome == .applyFailed)
        #expect(reply.problem == "disk full")
        #expect(try fixture.store.list(now: Date()).all.first?.status == .pending)
    }

    // MARK: the real stores

    @Test func anApprovedExceptionLandsInTheAllowlist() async throws {
        let fixture = try Self.fixture(prompt: Prompt(approve: true))
        let item = try await Self.propose(fixture.runtime)
        let before = AllowlistStore(baseDirectory: fixture.configDirectory).loadForValidate(workspacePath: nil)
        #expect(before == .missing)
        #expect(await Self.decide(fixture.runtime, item, .approve)?.outcome == .approved)
        guard case .ok(let entries) = AllowlistStore(baseDirectory: fixture.configDirectory)
            .loadForValidate(workspacePath: nil)
        else { Issue.record("allowlist not written"); return }
        #expect(entries.map(\.selector) == [.rule(try #require(parseAllowlistRuleID("core.git:reset-hard")))])
        #expect(entries.first?.reason == "rebasing the release branch")
    }

    @Test func anApprovedSafetyNormalIsSaved() async throws {
        let fixture = try Self.fixture(prompt: Prompt(approve: true))
        try SafetyStore(configDirectory: fixture.configDirectory).saveMachine(.strict)
        let item = try await Self.propose(fixture.runtime, .safetyNormal)
        #expect(await Self.decide(fixture.runtime, item, .approve)?.outcome == .approved)
        #expect(SafetyStore(configDirectory: fixture.configDirectory).loadMachine() == .normal)
    }

    @Test func anUnknownPackIsRefusedWhenFiled() async throws {
        let fixture = try Self.fixture()
        let result = await Self.call(fixture.runtime, .proposeLoosen(ProposeLoosenParams(
            change: .packOff(pack: "core.nope"), from: nil, cwd: nil, clientSemver: ProtocolVersion.serviceSemver)))
        guard case .proposeLoosen(let reply) = result else { Issue.record("\(result)"); return }
        #expect(reply.outcome == .invalid)
        #expect(reply.problem == "core.nope is not a pack id")
    }

    // MARK: events

    @Test func filingAndDecidingArePublishedAsProposalEvents() async throws {
        let fixture = try Self.fixture(prompt: Prompt(approve: true), applier: Applied().applier)
        let item = try await Self.propose(fixture.runtime)
        _ = await Self.decide(fixture.runtime, item, .approve)
        let reply = await fixture.runtime.events.next(after: 0, stream: nil, wait: nil, wire: false)
        let proposals = reply.events.compactMap { event -> LiveProposal? in
            if case .proposal(let proposal) = event.payload { return proposal }
            return nil
        }
        #expect(proposals == [
            LiveProposal(id: item.id, status: .pending, kind: "allowRule", from: "claude"),
            LiveProposal(id: item.id, status: .approved, kind: "allowRule", from: "claude"),
        ])
        let sequences = reply.events.map(\.sequence)
        #expect(sequences == sequences.sorted())
    }

    @Test func proposalEventsAreHiddenFromCallersThatCannotReadPending() {
        let event = LiveEvent(
            sequence: 1, atMs: 0,
            payload: .proposal(LiveProposal(id: ProposalID(number: 1), status: .pending, kind: "safetyNormal", from: nil)))
        #expect(LiveEventView(readsPending: false).visible(event) == nil)
        #expect(LiveEventView(readsPending: true).visible(event) == event)
    }

    // MARK: helpers

    static func rewrite(_ fixture: Fixture, _ edit: (inout LoosenProposal) -> Void) throws {
        let url = RVPolicyPaths.loosenProposalsFile(inConfigDir: fixture.configDirectory)
        let file = FileLockedJSONLStoreProbe.load(url)
        var rows = file
        for index in rows.indices { edit(&rows[index]) }
        try FileLockedJSONLStoreProbe.save(rows, to: url)
    }
}

/// Reads and writes the proposal file the way a same-user process could,
/// behind rvd's back.
enum FileLockedJSONLStoreProbe {
    static func load(_ url: URL) -> [LoosenProposal] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(LoosenProposal.self, from: Data($0.utf8)) }
    }

    static func save(_ rows: [LoosenProposal], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let lines = try rows.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
