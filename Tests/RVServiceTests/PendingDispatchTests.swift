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
        let response = await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())
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
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let pi = pinOkRecord(id: "pi-1", createdAt: now)
        let openCode = record(
            id: "oc-1",
            host: .opencode,
            session: "sess-oc",
            folder: "ws",
            createdAt: now.addingTimeInterval(1)
        )
        await approvals.seed(pi)
        await approvals.seed(openCode)
        let runtime = try makeRuntime(
            approvals: approvals,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id.rawValue) == ["pi-1", "oc-1"])

        let resolved = await resolveViaCore(
            pi,
            decision: .allowOnce,
            approvals: approvals,
            home: home,
            allowOnceDirectory: allowOnceDirectory
        )
        guard case .success(let reply) = resolved else {
            Issue.record("Allow-once Pi must resolve, got \(resolved)")
            return
        }
        #expect(reply.id == pi.id)
        #expect(reply.terminal)
        try assertNoCommand(IPCResponse(id: UUID(), result: .pendingResolve(reply)))

        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(remaining.items.map(\.id.rawValue) == ["oc-1"])
        let leftover = try #require(remaining.items.first)
        #expect(leftover.host == .opencode)
        #expect(await approvals.resolveCalls.map(\.id) == [pi.id])
        #expect(await approvals.resolveCalls.map(\.decision) == [.allowOnce])
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
        let denied = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )
        #expect(denied.result == .error(.authorizationDenied))
        let grants0 = AllowOnceStore(baseDirectory: allowOnceDirectory)
        let resolve = await HookAskResolver.resolve(
            params: resolveParams(wait, decision: .allowOnce),
            reviewedAction: reviewedAction(wait),
            pending: nil,
            grants: EphemeralAllowOnceTable(),
            projection: grants0,
            peek: { _, _, _ in
                Issue.record("missing coordinator must not peek")
                return EvaluationResult(outcome: .plain, matchingView: MatchingView(""))
            },
            now: now
        )
        #expect(resolve == .failure(.pendingCoordinatorUnavailable))
        let listed = await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())
        #expect(listed.result == .error(.pendingCoordinatorUnavailable))
        let watch = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: 0))),
            context: peerServiceContext()
        )
        #expect(watch.result == .error(.pendingCoordinatorUnavailable))

        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        #expect(await grants.list(now: now).isEmpty)
    }

    @Test func watchAcksUnchangedThenReturnsItemsAfterResolve() async throws {
        let approvals = FakePendingApprovals()
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let pi = pinOkRecord(id: "pi-1", createdAt: now)
        let openCode = record(
            id: "oc-1",
            host: .opencode,
            session: "sess-oc",
            folder: "ws",
            createdAt: now.addingTimeInterval(1)
        )
        await approvals.seed(pi)
        await approvals.seed(openCode)
        let runtime = try makeRuntime(
            approvals: approvals,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        let unchanged = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation))),
            context: peerServiceContext()
        )
        guard case .pendingWatch(let ack) = unchanged.result else {
            Issue.record("unchanged watch must be pendingWatch")
            return
        }
        #expect(ack.generation == listed.generation)
        #expect(ack.items.isEmpty)
        try assertNoCommand(unchanged)

        _ = await resolveViaCore(
            pi,
            decision: .allowOnce,
            approvals: approvals,
            home: home,
            allowOnceDirectory: allowOnceDirectory
        )
        let changed = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation))),
            context: peerServiceContext()
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
        let items = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())).items
        try #require(items.count == 3)
        #expect(items[0].sessionSuffix == "aaaa")
        #expect(items[1].sessionSuffix == "bbbb")
        #expect(items[2].sessionSuffix == nil)
    }

    @Test func missingFolderUsesPlaceholder() async throws {
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
        let runtime = try makeRuntime(approvals: approvals)
        let items = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())).items
        #expect(items.map(\.id.rawValue) == ["known"])
        let known = try #require(items.first)
        #expect(known.folder == ".")
        #expect(known.host == .pi)
    }

    @Test func resolveMapsLedgerErrors() async throws {
        let approvals = FakePendingApprovals()
        let wait = record(id: "ask-1", host: .pi, session: "sess-pi", folder: "ws", createdAt: now)
        await approvals.seed(wait)
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer { try? FileManager.default.removeItem(at: allowOnceDirectory) }
        let store = AllowOnceStore(baseDirectory: allowOnceDirectory)
        let at = now
        func resolve(
            _ params: PendingResolveParams
        ) async -> Result<PendingResolveReply, IPCError> {
            await HookAskResolver.resolve(
                params: params,
                reviewedAction: nil,
                pending: approvals,
                grants: EphemeralAllowOnceTable(),
                projection: store,
                peek: { _, _, _ in
                    Issue.record("deny path must not peek")
                    return EvaluationResult(outcome: .plain, matchingView: MatchingView(""))
                },
                now: at
            )
        }

        let missing = await resolve(
            PendingResolveParams(
                id: ApprovalID(rawValue: "nope"),
                decision: .deny,
                fingerprint: wait.fingerprint,
                identity: wait.identity
            )
        )
        #expect(missing == .failure(.pendingNotFound))

        let identity = await resolve(
            PendingResolveParams(
                id: wait.id,
                decision: .deny,
                fingerprint: wait.fingerprint,
                identity: ApprovalIdentity(
                    session: SessionID(validating: "other")!,
                    agent: wait.identity.agent
                )
            )
        )
        #expect(identity == .failure(.pendingIdentityMismatch))

        let fingerprint = await resolve(
            PendingResolveParams(
                id: wait.id,
                decision: .deny,
                fingerprint: ActionFingerprint(rawValue: "other"),
                identity: wait.identity
            )
        )
        #expect(fingerprint == .failure(.pendingFingerprintMismatch))

        _ = await resolve(resolveParams(wait, decision: .deny))
        let second = await resolve(resolveParams(wait, decision: .deny))
        #expect(second == .failure(.pendingAlreadyTerminal))
    }

    @Test func pendingDispatchDoesNotLogCommandText() async throws {
        let log = RecordingLog()
        let approvals = FakePendingApprovals()
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let wait = pinOkRecord(id: "log-1", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(
            approvals: approvals,
            log: log,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )

        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        _ = await runtime.dispatch(
            IPCRequest(method: .pendingWatch(PendingWatchParams(afterGeneration: listed.generation))),
            context: peerServiceContext()
        )
        // The authorized core resolves out of band; dispatch only ever
        // sees the denied bare method, which logs nothing.
        _ = await resolveViaCore(
            wait,
            decision: .allowOnce,
            approvals: approvals,
            home: home,
            allowOnceDirectory: allowOnceDirectory
        )
        let denied = await runtime.dispatch(
            IPCRequest(method: .pendingResolve(resolveParams(wait, decision: .allowOnce)))
        )
        #expect(denied.result == .error(.authorizationDenied))

        let events = log.snapshot
        #expect(events.map(\.method) == ["pendingList", "pendingWatch"])
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
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow))),
            context: peerServiceContext()
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
        // No persistent-rule authority exists yet (Step 8 stub): the gate
        // denies before the hard-stop check runs. Nothing is written.
        #expect(save.result == .error(.authorizationDenied))
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
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
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow))),
            context: peerServiceContext()
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
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [wait.id])
    }

    @Test func alwaysAllowSaveDeniedWithoutPersistentRuleAuthority() async throws {
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
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow))),
            context: peerServiceContext()
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
        // Remembered rules are out of scope for Step 8B: the save is
        // denied, the wait stays awaiting, and future evaluates still deny.
        #expect(save.result == .error(.authorizationDenied))
        #expect(await approvals.resolveCalls.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [wait.id])

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .deny = first.result.decision else {
            Issue.record("reset --hard must still deny without a saved rule")
            return
        }
    }

    @Test func alwaysAllowSaveDeniedForNormalizedWrapperRetry() async throws {
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
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow))),
            context: peerServiceContext()
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
        #expect(save.result == .error(.authorizationDenied))
        let command = ShellCommand(rawValue: "sudo git reset --hard")
        let view = EvaluationWorld.matchingView(of: command)
        #expect(view.rawValue == "git reset --hard")
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)

        let request = EvaluationRequest(
            command: command,
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .deny = first.result.decision else {
            Issue.record("wrapper reset --hard must still deny without a saved rule")
            return
        }
    }

    @Test func fileToolAlwaysAllowFailsClosedWithoutMatchingView() async throws {
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = PendingApproval(
            id: ApprovalID(rawValue: "file-pin"),
            identity: ApprovalIdentity(
                session: SessionID(validating: "sess-pi")!,
                agent: .claude
            ),
            action: .file(
                FileAction(
                    fingerprint: ActionFingerprint(rawValue: "file:claude:sess-pi:/tmp/ws:read:/tmp/a.md"),
                    file: FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/a.md")),
                    effects: ActionEffects(),
                    resources: ActionResources(path: "/tmp/a.md"),
                    scope: ActionScope(workingDirectory: wd("/tmp/ws"))
                )
            ),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: .keepWaiting,
            createdAt: now,
            expiresAt: now.addingTimeInterval(3600),
            state: .awaitingHuman
        )
        await approvals.seed(wait)
        let runtime = try makeRuntime(
            approvals: approvals,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )
        let preview = await runtime.dispatch(
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .allow))),
            context: peerServiceContext()
        )
        guard case .rulePreview(let reply) = preview.result else {
            Issue.record("file-tool Always-allow must preview")
            return
        }
        let save = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: reply.draft)
                )
            )
        )
        // The gate denies before the matching-view check runs.
        #expect(save.result == .error(.authorizationDenied))
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        #expect(try TypedRuleStore(baseDirectory: allowOnceDirectory).loadMachine().isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [wait.id])
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
        // The gate denies before the draft check runs, from every context.
        #expect(save.result == .error(.authorizationDenied))
        let peerSave = await runtime.dispatch(
            IPCRequest(
                method: .ruleSave(
                    RuleSaveParams(id: wait.id, polarity: .allow, draft: "forged")
                )
            ),
            context: peerServiceContext()
        )
        #expect(peerSave.result == .error(.authorizationDenied))
        #expect(await approvals.resolveCalls.isEmpty)
        let snap = AllowlistStore(baseDirectory: allowOnceDirectory)
            .loadUserSnapshot(workspacePath: nil, now: now)
        #expect(snap.entries.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [wait.id])
    }

    @Test func alwaysBlockSaveDeniedLeavesWaitAwaiting() async throws {
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
            IPCRequest(method: .rulePreview(RulePreviewParams(id: wait.id, polarity: .block))),
            context: peerServiceContext()
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
        #expect(save.result == .error(.authorizationDenied))
        #expect(await approvals.resolveCalls.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [wait.id])

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let again = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .deny = again.result.decision else {
            Issue.record("reset --hard must stay denied without a saved rule")
            return
        }
    }

    @Test func extraAllowOnceStillWorksWithoutATypedRule() async throws {
        let approvals = FakePendingApprovals()
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let wait = pinOkRecord(id: "once-1", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(
            approvals: approvals,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )
        let resolved = await resolveViaCore(
            wait,
            decision: .allowOnce,
            approvals: approvals,
            home: home,
            allowOnceDirectory: allowOnceDirectory
        )
        guard case .success(let reply) = resolved else {
            Issue.record("extra Allow once must still resolve, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        #expect(await approvals.resolveCalls.map(\.decision) == [.allowOnce])
        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(remaining.items.isEmpty)
    }

    @Test func failedProjectionStillResolvesAndPlantsMemoryGrant() async throws {
        // Step 8B.1: the projection is best-effort display. A sabotaged
        // directory swallows the audit row but the memory plant — the
        // sole authority — still succeeds and the wait resolves.
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        let homeURL = try isolatedHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let approvals = FakePendingApprovals()
        let wait = pinOkRecord(id: "plant-fail", createdAt: now)
        await approvals.seed(wait)
        let runtime = try makeRuntime(
            approvals: approvals,
            homeURL: homeURL,
            allowOnceDirectory: allowOnceDirectory
        )
        try FileManager.default.removeItem(at: allowOnceDirectory)
        #expect(FileManager.default.createFile(atPath: allowOnceDirectory.path, contents: Data()))

        let home = try #require(HomeDirectory(validating: homeURL.path))
        let memory = EphemeralAllowOnceTable()
        let resolved = await resolveViaCore(
            wait,
            decision: .allowOnce,
            approvals: approvals,
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            memory: memory
        )
        guard case .success(let reply) = resolved else {
            Issue.record("resolve must succeed despite projection failure, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        #expect(await approvals.resolveCalls.map(\.decision) == [.allowOnce])
        let remaining = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(remaining.items.isEmpty)
        let grants = AllowOnceStore(baseDirectory: allowOnceDirectory)
        #expect(await grants.list(now: now).filter { $0.kind == .granted }.isEmpty)
        #expect(
            await memory.hasGrant(
                matchingView: "git reset --hard", cwd: wd("/tmp/ws"), now: now
            )
        )
    }

    @Test func allowOncePeekUsesCompileSetAfterPackEnable() async throws {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let approvals = FakePendingApprovals()
        let store = AllowOnceStore(baseDirectory: allowOnceDirectory)
        let freshPeekWorld = {
            LiveEvaluateWorld(home: home, store: store, clock: { self.now })
        }
        let wait = record(
            id: "sqlite-1",
            host: .pi,
            session: "sess-pi",
            folder: "ws",
            createdAt: now,
            effects: [],
            branchName: nil,
            command: "DROP TABLE users"
        )
        let early = record(
            id: "sqlite-0",
            host: .pi,
            session: "sess-pi",
            folder: "ws",
            createdAt: now,
            effects: [],
            branchName: nil,
            command: "DROP TABLE users"
        )
        await approvals.seed(wait)
        await approvals.seed(early)
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { now },
            pendingApprovals: .coordinator(approvals)
        )
        // Generic IPC evaluate/setPackEnabled stay denied (.agent /
        // .ownerMutation); the daemon reaches both in process.
        let dropTable = EvaluationRequest(
            command: ShellCommand(rawValue: "DROP TABLE users"),
            enabledPacks: dayOnePackIDs
        )
        let before = await runtime.evaluate(dropTable, cwd: wd("/tmp/ws"))
        guard case .allow = before.result.decision else {
            Issue.record("DROP TABLE must allow before database.sqlite enable")
            return
        }

        // Pre-enable resolve: the fresh peek sees day-one only, allows, and
        // resolves without planting a grant.
        let world0 = freshPeekWorld()
        let earlyResolve = await HookAskResolver.resolve(
            params: resolveParams(early, decision: .allowOnce),
            reviewedAction: reviewedAction(early),
            pending: approvals,
            grants: EphemeralAllowOnceTable(),
            projection: store,
            peek: { command, cwd, now in
                await world0.peek(command: command, cwd: cwd)
            },
            now: now
        )
        guard case .success(let earlyReply) = earlyResolve else {
            Issue.record("pre-enable allow-once must resolve, got \(earlyResolve)")
            return
        }
        #expect(earlyReply.terminal)
        #expect(await store.list(now: now).filter { $0.kind == .granted }.isEmpty)

        let sqlite = PackID(rawValue: "database.sqlite")
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])
        let catalog = try PacksFacade.makeCatalog(home: home)
        #expect(catalog.records.first(where: { $0.id == sqlite })?.isEnabled == true)

        // Post-enable resolve: the fresh peek walks the on-disk set, sees
        // database.sqlite deny DROP TABLE, and plants exactly one grant.
        let world1 = freshPeekWorld()
        let resolved = await HookAskResolver.resolve(
            params: resolveParams(wait, decision: .allowOnce),
            reviewedAction: reviewedAction(wait),
            pending: approvals,
            grants: EphemeralAllowOnceTable(),
            projection: store,
            peek: { command, cwd, now in
                await world1.peek(command: command, cwd: cwd)
            },
            now: now
        )
        guard case .success(let reply) = resolved else {
            Issue.record("allow-once after pack enable must resolve, got \(resolved)")
            return
        }
        #expect(reply.terminal)
        #expect(await store.list(now: now).filter { $0.kind == .granted }.count == 1)
    }

    @Test func hookEvaluateAskOnPiPersistsWaitWithoutCommandOnList() async throws {
        let approvals = FakePendingApprovals()
        let runtime = try makeRuntime(approvals: approvals)
        let stdin =
            #"{"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"}}"#
        let asked = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: stdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = asked.result else {
            Issue.record("Pi reset-hard hookEvaluate must dispatch")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8))
        let json = try #require(object as? [String: Any])
        // Policy verdict is ASK (the row below proves it); the wire renders
        // deny because no host can pause for a human.
        #expect(json["decision"] as? String == "deny")
        #expect(await approvals.createCalls.count == 1)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.count == 1)
        let item = try #require(listed.items.first)
        #expect(item.host == .pi)
        #expect(item.folder == "ws")
        #expect(item.identity.session.rawValue == "sess-pi")
        try assertNoCommand(asked)
        try assertNoCommand(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
    }

    @Test func hookEvaluateAskWithoutSessionDoesNotPersist() async throws {
        let approvals = FakePendingApprovals()
        let runtime = try makeRuntime(approvals: approvals)
        let stdin =
            #"{"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}"#
        let asked = await runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: stdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = asked.result else {
            Issue.record("Pi reset-hard without session must still dispatch")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8))
        let json = try #require(object as? [String: Any])
        #expect(json["decision"] as? String == "deny")
        #expect(await approvals.createCalls.isEmpty)
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.isEmpty)
    }

    @Test func automaticStoreListsCreatedWaits() async throws {
        let homeURL = try isolatedHomeDirectory()
        let allowOnceDirectory = try isolatedAllowOnceDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeURL)
            try? FileManager.default.removeItem(at: allowOnceDirectory)
        }
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let store = PendingApprovalStore.makeLive(home: home)
        let created = try await store.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: "live-1"),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
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
        let listed = try requireList(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
        #expect(listed.items.map(\.id) == [created.id])
        let item = try #require(listed.items.first)
        #expect(item.host == .pi)
        #expect(item.folder == "ws")
        #expect(item.actionKind == "discard working tree")
        try assertNoCommand(await runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext()))
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

    private func reviewedAction(
        _ record: PendingApproval
    ) -> (command: ShellCommand?, cwd: WorkingDirectory?) {
        (record.action.supportingCommand, record.action.scope.workingDirectory)
    }

    /// Owner-authorized resolve core over the test's stores. Generic IPC
    /// `pendingResolve` stays denied; the ceremony transports reach this
    /// same core after proving the human.
    private func resolveViaCore(
        _ record: PendingApproval,
        decision: PendingResolveDecision,
        approvals: FakePendingApprovals,
        home: HomeDirectory,
        allowOnceDirectory: URL,
        memory: EphemeralAllowOnceTable = EphemeralAllowOnceTable()
    ) async -> Result<PendingResolveReply, IPCError> {
        let store = AllowOnceStore(baseDirectory: allowOnceDirectory)
        return await HookAskResolver.resolve(
            params: resolveParams(record, decision: decision),
            reviewedAction: decision == .deny ? nil : reviewedAction(record),
            pending: approvals,
            grants: memory,
            projection: store,
            peek: { command, cwd, now in
                await LiveEvaluateWorld(home: home, store: store, grants: memory, clock: { now })
                    .peek(command: command, cwd: cwd)
            },
            now: now
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
                session: SessionID(validating: session)!,
                agent: host
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
