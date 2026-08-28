import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

struct PendingDispatchTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let secretCommand = "GITHUB_TOKEN=ghp_secret git push --force origin main"

    @Test func listOmitsCommandAndOrdersOldestFirst() async throws {
        let approvals = FakePendingApprovals()
        await approvals.seed(
            record(
                id: "newer",
                host: .opencode,
                session: "sess-oc",
                folder: "ws",
                createdAt: now.addingTimeInterval(10)
            )
        )
        await approvals.seed(
            record(
                id: "older",
                host: .pi,
                session: "sess-pi",
                folder: "ws",
                createdAt: now
            )
        )
        let runtime = try makeRuntime(approvals: approvals)
        let response = await runtime.dispatch(IPCRequest(method: .pendingList))
        let reply = try requireList(response)
        #expect(reply.items.map(\.id.rawValue) == ["older", "newer"])
        #expect(reply.items.map(\.host) == [.pi, .opencode])
        #expect(reply.items.map(\.folder) == ["ws", "ws"])
        #expect(reply.items.allSatisfy { $0.sessionSuffix == nil })
        let older = try #require(reply.items.first)
        #expect(older.actionKind == "shared branch mutation on origin/main")
        #expect(reply.items.allSatisfy { $0.actionKind.contains("git") == false })
        try assertNoCommand(response)
    }

    @Test func allowOnceOnPiLeavesOpenCodeAwaiting() async throws {
        let approvals = FakePendingApprovals()
        let pi = record(id: "pi-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        let openCode = record(
            id: "oc-1",
            host: .opencode,
            session: "sess-oc",
            folder: "ws",
            createdAt: now.addingTimeInterval(1)
        )
        await approvals.seed(pi)
        await approvals.seed(openCode)
        let runtime = try makeRuntime(approvals: approvals)

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.map(\.id.rawValue) == ["pi-1", "oc-1"])

        let resolved = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(pi, decision: .allowOnce)))
        )
        guard case .pendingResolve(let reply) = resolved.result else {
            Issue.record("Allow-once Pi must resolve")
            return
        }
        #expect(reply.id == pi.id)
        #expect(reply.terminal)
        try assertNoCommand(resolved)

        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(remaining.items.map(\.id.rawValue) == ["oc-1"])
        let leftover = try #require(remaining.items.first)
        #expect(leftover.host == .opencode)
        #expect(await approvals.resolveCalls.map(\.id) == [pi.id])
        #expect(await approvals.resolveCalls.map(\.decision) == [.allowOnce])
    }

    @Test func emptySessionCannotAllowOnceButDenyStillResolves() async throws {
        let approvals = FakePendingApprovals()
        let wait = record(id: "empty-1", host: .pi, session: "", folder: "ws", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals)

        let allow = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )
        #expect(allow.result == .error(.pendingIdentityMismatch))
        #expect(await approvals.resolveCalls.isEmpty)

        let deny = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .deny)))
        )
        guard case .pendingResolve(let reply) = deny.result else {
            Issue.record("Deny may proceed with an empty session")
            return
        }
        #expect(reply.id == wait.id)
        #expect(reply.terminal)
        #expect(await approvals.resolveCalls.map(\.decision) == [.deny])

        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(remaining.items.isEmpty)
    }

    @Test func missingCoordinatorFailsClosedWithoutSpendingAGrant() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { now },
            pendingApprovals: .missing
        )
        let wait = record(id: "down-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        let resolve = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )
        #expect(resolve.result == .error(.engine("pending coordinator unavailable")))
        let listed = await runtime.dispatch(IPCRequest(method: .pendingList))
        #expect(listed.result == .error(.engine("pending coordinator unavailable")))
        let watch = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: 0)))
        )
        #expect(watch.result == .error(.engine("pending coordinator unavailable")))

        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        #expect(await grants.list(now: now).isEmpty)
    }

    @Test func watchAcksUnchangedThenReturnsItemsAfterResolve() async throws {
        let approvals = FakePendingApprovals()
        let pi = record(id: "pi-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        let openCode = record(
            id: "oc-1",
            host: .opencode,
            session: "sess-oc",
            folder: "ws",
            createdAt: now.addingTimeInterval(1)
        )
        await approvals.seed(pi)
        await approvals.seed(openCode)
        let runtime = try makeRuntime(approvals: approvals)

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        let unchanged = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation)))
        )
        guard case .pendingWatch(let ack) = unchanged.result else {
            Issue.record("unchanged watch must be pendingWatch")
            return
        }
        #expect(ack.generation == listed.generation)
        #expect(ack.items.isEmpty)
        try assertNoCommand(unchanged)

        _ = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(pi, decision: .allowOnce)))
        )
        let changed = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation)))
        )
        guard case .pendingWatch(let next) = changed.result else {
            Issue.record("changed watch must be pendingWatch")
            return
        }
        #expect(next.generation != listed.generation)
        #expect(next.items.map(\.id.rawValue) == ["oc-1"])
        try assertNoCommand(changed)
    }

    @Test func sessionSuffixOnlyWhenAskLineCollides() async throws {
        let approvals = FakePendingApprovals()
        await approvals.seed(
            record(id: "a", host: .pi, session: "session-aaaa", folder: "ws", createdAt: now)
        )
        await approvals.seed(
            record(
                id: "b",
                host: .pi,
                session: "session-bbbb",
                folder: "ws",
                createdAt: now.addingTimeInterval(1)
            )
        )
        await approvals.seed(
            record(
                id: "c",
                host: .opencode,
                session: "session-cccc",
                folder: "ws",
                createdAt: now.addingTimeInterval(2)
            )
        )
        let runtime = try makeRuntime(approvals: approvals)
        let items = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList))).items
        try #require(items.count == 3)
        #expect(items[0].sessionSuffix == "aaaa")
        #expect(items[1].sessionSuffix == "bbbb")
        #expect(items[2].sessionSuffix == nil)
    }

    @Test func unknownHostIsOmittedAndMissingFolderUsesPlaceholder() async throws {
        let approvals = FakePendingApprovals()
        await approvals.seed(
            record(
                id: "known",
                host: .pi,
                session: "sess-pi",
                folder: nil,
                createdAt: now
            )
        )
        var unknown = record(
            id: "ghost",
            host: .pi,
            session: "sess-x",
            folder: "ws",
            createdAt: now.addingTimeInterval(1)
        )
        unknown.identity.agent = AgentIdentity(rawValue: "not-a-host")
        await approvals.seed(unknown)
        let runtime = try makeRuntime(approvals: approvals)
        let items = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList))).items
        #expect(items.map(\.id.rawValue) == ["known"])
        let known = try #require(items.first)
        #expect(known.folder == ".")
    }

    @Test func resolveMapsLedgerErrors() async throws {
        let approvals = FakePendingApprovals()
        let wait = record(id: "ask-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals)

        let missing = await runtime.dispatch(
            IPCRequest(
                method: .pendingResolve(
                    PendingResolveParams(
                        id: ApprovalID(rawValue: "nope"),
                        decision: .deny,
                        fingerprint: wait.fingerprint,
                        identity: wait.identity
                    )
                )
            )
        )
        #expect(missing.result == .error(.pendingNotFound))

        let identity = await runtime.dispatch(
            IPCRequest(
                method: .pendingResolve(
                    PendingResolveParams(
                        id: wait.id,
                        decision: .deny,
                        fingerprint: wait.fingerprint,
                        identity: ApprovalIdentity(
                            session: SessionIdentity(rawValue: "other"),
                            agent: wait.identity.agent
                        )
                    )
                )
            )
        )
        #expect(identity.result == .error(.pendingIdentityMismatch))

        let fingerprint = await runtime.dispatch(
            IPCRequest(
                method: .pendingResolve(
                    PendingResolveParams(
                        id: wait.id,
                        decision: .deny,
                        fingerprint: ActionFingerprint(rawValue: "other"),
                        identity: wait.identity
                    )
                )
            )
        )
        #expect(fingerprint.result == .error(.pendingFingerprintMismatch))

        _ = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .deny)))
        )
        let second = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .deny)))
        )
        #expect(second.result == .error(.pendingAlreadyTerminal))
    }

    @Test func pendingDispatchDoesNotLogCommandText() async throws {
        let log = RecordingLog()
        let approvals = FakePendingApprovals()
        let wait = record(id: "log-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, log: log)

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        _ = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation)))
        )
        _ = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )

        let events = log.snapshot
        #expect(events.map(\.method) == ["pendingList", "pendingWatch", "pendingResolve"])
        #expect(events.allSatisfy { $0.decision == nil && $0.ruleID == nil })
        let blob = events.map { "\($0.method)|\($0.decision ?? "")|\($0.ruleID ?? "")" }.joined()
        #expect(blob.contains("ghp_secret") == false)
        #expect(blob.contains("git push") == false)
        #expect(blob.contains(secretCommand) == false)
    }

    @Test func alwaysAllowHardStopPreviewForbidsSaveAndWritesNothing() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = record(id: "ask-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)
        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow)))
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("hard-stop Always-allow must preview")
            return
        }
        #expect(reply.allowedToSave == false)
        #expect(reply.sentence.contains("hard stop"))
        try assertNoCommand(preview)

        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: reply.draft)
                )
            )
        )
        #expect(save.result == .error(.ruleHardStop))
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.map(\.id) == [wait.id])
    }

    @Test func previewWithoutSaveLeavesWaitAwaitingHuman() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "pin-ok", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)

        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow)))
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("pin-ok Always-allow must preview")
            return
        }
        #expect(reply.allowedToSave == true)
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.map(\.id) == [wait.id])
    }

    @Test func alwaysAllowSaveAuthorizesFutureEvaluateWithoutExtraClick() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "pin-ok", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)

        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow)))
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("pin-ok Always-allow must preview")
            return
        }
        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: reply.draft)
                )
            )
        )
        guard case .ruleSave(let saved) = save.result else {
            Issue.record("pin-ok Always-allow must save, got \(save.result)")
            return
        }
        #expect(saved.waitResolved == true)
        #expect(saved.ruleID.pack.rawValue == "pin.allow")
        #expect(await approvals.resolveCalls.map(\.decision) == [.createRule])
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.isEmpty)

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate after Always-allow")
            return
        }
        #expect(allowed.result.decision == .allow)
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let still) = second.result else {
            Issue.record("expected second evaluate after Always-allow")
            return
        }
        #expect(still.result.decision == .allow)
    }

    @Test func alwaysAllowSaveAuthorizesNormalizedWrapperRetry() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(
            id: "pin-sudo",
            createdAt: now,
            command: "sudo git reset --hard"
        )
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)

        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow)))
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("wrapper Always-allow must preview")
            return
        }
        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: reply.draft)
                )
            )
        )
        guard case .ruleSave = save.result else {
            Issue.record("wrapper Always-allow must save, got \(save.result)")
            return
        }

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "sudo git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate after wrapper Always-allow")
            return
        }
        #expect(allowed.result.decision == .allow)
        let unwrapped = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: unwrapped, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let still) = second.result else {
            Issue.record("expected unwrapped evaluate after wrapper Always-allow")
            return
        }
        #expect(still.result.decision == .allow)
    }

    @Test func ruleSaveDraftMismatchWritesNothing() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "pin-ok", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)

        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: "forged")
                )
            )
        )
        #expect(save.result == .error(.ruleDraftMismatch))
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.map(\.id) == [wait.id])
    }

    @Test func alwaysBlockSaveDeniesThisWait() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "block-ok", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals, homeURL: homeURL, allowOnceDirectory: allowOnceDirectory)

        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .block)))
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("Always-block must preview")
            return
        }
        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .block, draft: reply.draft)
                )
            )
        )
        guard case .ruleSave(let saved) = save.result else {
            Issue.record("Always-block must save, got \(save.result)")
            return
        }
        #expect(saved.waitResolved == true)
        #expect(await approvals.resolveCalls.map(\.decision) == [.deny])
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.isEmpty)

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let again = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: wd("/tmp/ws"))))
        )
        guard case .evaluate(let denied) = again.result else {
            Issue.record("expected evaluate after Always-block")
            return
        }
        guard case .deny = denied.result.decision else {
            Issue.record("Always-block must keep future evaluates denied")
            return
        }
    }

    @Test func extraAllowOnceStillWorksWithoutATypedRule() async throws {
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "once-1", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(approvals: approvals)
        let resolved = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )
        guard case .pendingResolve(let reply) = resolved.result else {
            Issue.record("extra Allow once must still resolve")
            return
        }
        #expect(reply.terminal)
        #expect(await approvals.resolveCalls.map(\.decision) == [.allowOnce])
        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(remaining.items.isEmpty)
    }

    @Test func automaticStoreListsCreatedWaits() async throws {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let store = PendingApprovalStore.live(home: home)
        let created = try await store.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: "live-1"),
                identity: ApprovalIdentity(
                    session: SessionIdentity(rawValue: "sess-pi"),
                    agent: AgentIdentity(rawValue: HookHost.pi.rawValue)
                ),
                action: .shell(
                    ShellAction(
                        fingerprint: ActionFingerprint(rawValue: "shell:live-1"),
                        effects: ActionEffects(kinds: [.workingTreeDiscard]),
                        scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                        supportingCommand: ShellCommand(rawValue: secretCommand)
                    )
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .keepWaiting
            ),
            now: now
        )
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { now },
            pendingApprovals: .automatic
        )
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList)))
        #expect(listed.items.map(\.id) == [created.id])
        let item = try #require(listed.items.first)
        #expect(item.host == .pi)
        #expect(item.folder == "ws")
        #expect(item.actionKind == "discard working tree")
        try assertNoCommand(await runtime.dispatch(IPCRequest(method: .pendingList)))
    }

    private func makeRuntime(
        approvals: FakePendingApprovals,
        log: (any ServiceLog)? = nil,
        homeURL: URL? = nil,
        allowOnceDirectory: URL? = nil
    ) throws -> ServiceRuntime {
        let homeURL = try homeURL ?? isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        return ServiceRuntime(
            home: home,
            allowOnceDirectory: try allowOnceDirectory ?? isolatedAllowOnceDirectory(),
            log: log,
            clock: { now },
            pendingApprovals: .coordinator(approvals)
        )
    }

    private func requireList(_ response: IPCResponse) throws -> PendingListReply {
        guard case .pendingList(let reply) = response.result else {
            Issue.record("expected pendingList reply, got \(response.result)")
            throw DispatchExpectation()
        }
        return reply
    }

    private struct DispatchExpectation: Error {}

    private func resolveParams(
        _ record: PendingApproval,
        decision: PendingResolveDecision
    ) -> PendingResolveParams {
        PendingResolveParams(
            id: record.id,
            decision: decision,
            fingerprint: record.fingerprint,
            identity: record.identity
        )
    }

    private func pinOkRecord(
        id: String,
        createdAt: Date,
        command: String = "git reset --hard"
    ) -> PendingApproval {
        record(
            id: id,
            host: .pi,
            session: "sess-pi",
            folder: "ws",
            createdAt: createdAt,
            effects: [],
            branchName: nil,
            command: command
        )
    }

    private func record(
        id: String,
        host: HookHost,
        session: String,
        folder: String?,
        createdAt: Date,
        effects: [ActionEffectKind] = [.remoteSharedBranchMutation],
        branchName: String? = "main",
        command: String? = nil
    ) -> PendingApproval {
        PendingApproval(
            id: ApprovalID(rawValue: id),
            identity: ApprovalIdentity(
                session: SessionIdentity(rawValue: session),
                agent: AgentIdentity(rawValue: host.rawValue)
            ),
            action: .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(rawValue: "shell:\(id)"),
                    effects: ActionEffects(kinds: effects),
                    resources: ActionResources(remoteName: "origin", branchName: branchName),
                    scope: ActionScope(workingDirectory: folder.map { wd("/tmp/\($0)") }),
                    supportingCommand: ShellCommand(rawValue: command ?? secretCommand)
                )
            ),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: .keepWaiting,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3600),
            state: .awaitingHuman
        )
    }

    private func assertNoCommand(_ response: IPCResponse) throws {
        let data = try IPCJSON.encode(response)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("ghp_secret") == false)
        #expect(text.contains("git push --force") == false)
        #expect(text.contains("supportingCommand") == false)
        let object = try JSONSerialization.jsonObject(with: data)
        assertNoCommandKeys(object)
    }

    private func assertNoCommandKeys(_ object: Any) {
        switch object {
        case let dict as [String: Any]:
            #expect(dict["command"] == nil)
            #expect(dict["supportingCommand"] == nil)
            for value in dict.values {
                assertNoCommandKeys(value)
            }
        case let array as [Any]:
            for value in array {
                assertNoCommandKeys(value)
            }
        default:
            break
        }
    }
}
