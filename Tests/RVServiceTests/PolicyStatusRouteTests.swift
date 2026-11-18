import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// `policyStatus`: rvd reports the typed-policy load its evaluation runs,
/// for its own HOME and the caller's cwd.
@Suite("PolicyStatusRoute")
struct PolicyStatusRouteTests {
    @Test func cleanLoad_isReportedLoadedFromRvdsHome() async throws {
        try await withRuntime { runtime, home, workspace in
            let document = PolicyDocument(rules: [Self.denyReset])
            try TypedRuleStore(baseDirectory: RVPolicyPaths.configDirectory(home: home)).saveMachine(document)

            let status = try await Self.status(runtime, cwd: workspace)

            #expect(status.state == .loaded)
            #expect(status.machine?.hash == PolicyRevisionIdentity.hash(document))
            #expect(status.configDirectory == RVPolicyPaths.configDirectory(home: home).path)
            #expect(status.workspace == workspace.path)
        }
    }

    /// The route and evaluation read the same files the same way: a corrupt
    /// repo policy is `failed` here and a `typed-rules-invalid` deny there.
    @Test func corruptRepoPolicy_isFailed_andEvaluationDeniesTheSame() async throws {
        try await withRuntime { runtime, _, workspace in
            let url = TypedRuleStore.repoFileURL(workspace: workspace)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "[[rule]\nbroken".write(to: url, atomically: true, encoding: .utf8)

            let status = try await Self.status(runtime, cwd: workspace)
            #expect(status.state == .failed)
            #expect(status.failure == .repoInvalid)

            let reply = await runtime.evaluate(
                EvaluationRequest(command: ShellCommand(rawValue: "ls"), enabledPacks: dayOnePackIDs),
                cwd: WorkingDirectory(validating: workspace.path))
            guard case .deny(let deny) = reply.result.decision else {
                Issue.record("a failed load must deny, got \(reply.result.decision)")
                return
            }
            #expect(deny.ruleID == BuiltinRule.typedRulesInvalid.ruleID)
        }
    }

    enum Layer: String, CaseIterable, Sendable { case machine, repo, ceiling }

    /// Files evaluation must refuse rather than parse, follow or wait on.
    enum Hazard: String, CaseIterable, Sendable {
        case corrupt
        /// A FIFO with no writer: a blocking open would hang every hook.
        case fifo
        /// Valid TOML past the size cap.
        case oversized
        /// A symlink to a valid policy file.
        case symlink
    }

    /// Every layer and every unloadable file: status says `failed` with the
    /// layer's step, and evaluation denies `typed-rules-invalid`, from the
    /// same read. Neither blocks.
    @Test(arguments: Layer.allCases, Hazard.allCases)
    func unloadableLayer_isFailed_andEvaluationDenies(layer: Layer, hazard: Hazard) async throws {
        try await withRuntime { runtime, home, workspace in
            let config = RVPolicyPaths.configDirectory(home: home)
            let url = switch layer {
            case .machine: TypedRuleStore(baseDirectory: config).machineFileURL
            case .repo: TypedRuleStore.repoFileURL(workspace: workspace)
            case .ceiling: RVPolicyPaths.policyCeilingFile(inConfigDir: config)
            }
            try Self.plant(hazard, at: url, scratch: workspace)

            let status = try await Self.status(runtime, cwd: workspace)
            let expected: PolicyLoadStatus.Failure = switch layer {
            case .machine: .machineInvalid
            case .repo: .repoInvalid
            case .ceiling: .ceilingInvalid
            }
            #expect(status.state == .failed)
            #expect(status.failure == expected)

            let reply = await runtime.evaluate(
                EvaluationRequest(command: ShellCommand(rawValue: "ls"), enabledPacks: dayOnePackIDs),
                cwd: WorkingDirectory(validating: workspace.path))
            guard case .deny(let deny) = reply.result.decision else {
                Issue.record("\(layer) \(hazard): a failed load must deny, got \(reply.result.decision)")
                return
            }
            #expect(deny.ruleID == BuiltinRule.typedRulesInvalid.ruleID)
        }
    }

    /// Loads that block (slow containment, slow disk) hold neither the actor
    /// nor more than `limit` threads: while both slots are held, hooks still
    /// evaluate and a third status request is answered `busy` at once.
    @Test(.timeLimit(.minutes(1)))
    func blockedLoads_neverBlockTheActor_andPastTheCapAnswerBusy() async throws {
        let gate = DispatchSemaphore(value: 0)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let loaded = PolicyLoadStatus(state: .loaded)
        let service = PolicyStatusService(limit: 2) { _, _ in
            startedContinuation.yield()
            gate.wait()
            return loaded
        }
        try await withRuntime(policyStatusService: service) { runtime, _, workspace in
            async let first = Self.reply(runtime, cwd: workspace)
            async let second = Self.reply(runtime, cwd: workspace)
            var starts = started.makeAsyncIterator()
            _ = await starts.next()
            _ = await starts.next()

            let third = try await Self.reply(runtime, cwd: workspace)
            #expect(third == PolicyStatusReply.busy)
            let evaluated = await runtime.evaluate(
                EvaluationRequest(command: ShellCommand(rawValue: "ls"), enabledPacks: dayOnePackIDs),
                cwd: WorkingDirectory(validating: workspace.path))
            if case .deny(let deny) = evaluated.result.decision {
                Issue.record("ls in an empty workspace should not deny: \(deny.ruleID)")
            }

            gate.signal()
            gate.signal()
            let answers = try await [first, second]
            #expect(answers == [PolicyStatusReply.status(loaded), PolicyStatusReply.status(loaded)])

            // Slots free when their loads return.
            gate.signal()
            let afterRelease = try await Self.reply(runtime, cwd: workspace)
            #expect(afterRelease == PolicyStatusReply.status(loaded))
        }
    }

    @Test func isReadOnlyDiagnostic_noOwnerAuthNeeded() {
        let method = IPCMethod.policyStatus(PolicyStatusParams(cwd: nil))
        #expect(ServiceMethodAuthorization.requirement(for: method) == .diagnostic)
        #expect(ServiceMethodAuthorization.permits(method, context: .unauthenticated))
    }

    // MARK: Helpers

    private static let denyReset = PolicyDocumentRule(
        id: RuleID(rawValue: "typed.git:no-reset")!, verdict: .deny, predicate: .gitReset(mode: nil))

    private static func status(_ runtime: ServiceRuntime, cwd: URL) async throws -> PolicyLoadStatus {
        guard case .status(let status) = try await reply(runtime, cwd: cwd) else {
            throw StatusRouteError.unexpected("busy")
        }
        return status
    }

    private static func reply(_ runtime: ServiceRuntime, cwd: URL) async throws -> PolicyStatusReply {
        let response = await runtime.dispatch(IPCRequest(
            method: .policyStatus(PolicyStatusParams(cwd: WorkingDirectory(validating: cwd.path)))))
        guard case .policyStatus(let reply) = response.result else {
            throw StatusRouteError.unexpected("\(response.result)")
        }
        return reply
    }

    private static let validPolicy = """
        schema_version = 1

        [[rule]]
        id = "typed.git:no-force-push"
        verdict = "deny"
        predicate = "gitPush"
        force = "force"

        """

    private static func plant(_ hazard: Hazard, at url: URL, scratch: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch hazard {
        case .corrupt:
            try "[[rule]\nbroken".write(to: url, atomically: true, encoding: .utf8)
        case .fifo:
            #expect(mkfifo(url.path, 0o600) == 0)
        case .oversized:
            let padding = "# " + String(repeating: "x", count: TypedRuleStore.maximumDocumentBytes) + "\n"
            try (padding + validPolicy).write(to: url, atomically: true, encoding: .utf8)
        case .symlink:
            let target = scratch.appendingPathComponent("elsewhere-\(UUID().uuidString).toml")
            try validPolicy.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    private enum StatusRouteError: Error { case unexpected(String) }

    private func withRuntime(
        policyStatusService: PolicyStatusService = PolicyStatusService(),
        _ body: (ServiceRuntime, HomeDirectory, URL) async throws -> Void
    ) async throws {
        let homeURL = try isolatedHomeDirectory()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-status-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: workspace)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(), idleExitSeconds: IdleWatchdog.defaultSeconds,
            log: nil, analytics: nil, clock: { Date() }, pendingApprovals: .automatic,
            ceremonies: WorkspaceOperatorCeremonyService(), policyStatusService: policyStatusService)
        try await body(runtime, home, workspace)
    }
}
