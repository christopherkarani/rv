import Foundation
import Testing
import RVDomain
@testable import RVPolicy

@Suite("PendingApproval store")
struct PendingApprovalStoreTests {
    @Test func processRestartReloadsPendingAndResolvedRecords() async throws {
        let root = try isolatedDirectory()
        let first = PendingApprovalStore(baseDirectory: root)
        let request = Self.request(id: "restart-1")
        let created = try await first.create(request, now: Self.now)
        #expect(created.state == .awaitingHuman)

        let afterRestart = PendingApprovalStore(baseDirectory: root)
        let reloaded = try await afterRestart.load(id: created.id, now: Self.now)
        #expect(reloaded == created)
        let listed = try await afterRestart.list(now: Self.now)
        #expect(listed.map(\.id) == [created.id])

        let resolved = try await afterRestart.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        guard case .resolved = resolved.state else {
            Issue.record("resolve must persist")
            return
        }

        let third = PendingApprovalStore(baseDirectory: root)
        let consumption = try await third.consume(
            id: created.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(consumption.decision == .allowOnce)
        await #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try await third.consume(
                id: created.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func concurrentResolveWinsOnce() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(Self.request(id: "race-resolve"), now: Self.now)
        let a = PendingApprovalStore(baseDirectory: root)
        let b = PendingApprovalStore(baseDirectory: root)
        async let first = resultOf {
            try await a.resolve(
                id: created.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        async let second = resultOf {
            try await b.resolve(
                id: created.id,
                decision: .deny,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        let results = await [first, second]
        #expect(results.filter(\.isSuccess).count == 1)
        #expect(results.filter { $0 == .alreadyResolved }.count == 1)
        let winner = try await writer.load(id: created.id, now: Self.now)
        guard case .resolved(let resolution) = winner.state else {
            Issue.record("exactly one resolve must persist")
            return
        }
        #expect(resolution.decision == .allowOnce || resolution.decision == .deny)
    }

    @Test func concurrentConsumeWinsOnce() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(Self.request(id: "race-consume"), now: Self.now)
        _ = try await writer.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let a = PendingApprovalStore(baseDirectory: root)
        let b = PendingApprovalStore(baseDirectory: root)
        async let first = consumeResult(a, id: created.id)
        async let second = consumeResult(b, id: created.id)
        let results = await [first, second]
        #expect(results.filter(\.isSuccess).count == 1)
        #expect(results.filter { $0 == .alreadyConsumed }.count == 1)
    }

    @Test func timeoutPersistsAcrossRestartAndRejectsStaleApprove() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(
            Self.request(id: "timeout-1", timeoutPolicy: .autoDeny, ttl: 1),
            now: Self.now
        )
        let later = Self.now.addingTimeInterval(2)
        let listed = try await writer.list(now: later)
        #expect(listed.isEmpty)
        let timedOut = try await writer.load(id: created.id, now: later)
        guard case .timedOut = timedOut.state else {
            Issue.record("autoDeny must persist timedOut")
            return
        }

        let restarted = PendingApprovalStore(baseDirectory: root)
        await #expect(throws: PendingApprovalError.timedOut) {
            _ = try await restarted.resolve(
                id: created.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: later
            )
        }
        await #expect(throws: PendingApprovalError.timedOut) {
            _ = try await restarted.consume(
                id: created.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: later
            )
        }
    }

    @Test func cancelPersistsAndCannotAuthorizeAfterRestart() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(Self.request(id: "cancel-1"), now: Self.now)
        _ = try await writer.cancel(id: created.id, now: Self.now)
        let restarted = PendingApprovalStore(baseDirectory: root)
        await #expect(throws: PendingApprovalError.canceled) {
            _ = try await restarted.resolve(
                id: created.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        await #expect(throws: PendingApprovalError.canceled) {
            _ = try await restarted.consume(
                id: created.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func keepWaitingSurvivesRestartPastDeadline() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(
            Self.request(id: "keep-1", timeoutPolicy: .keepWaiting, ttl: 1),
            now: Self.now
        )
        let later = Self.now.addingTimeInterval(2)
        let restarted = PendingApprovalStore(baseDirectory: root)
        let listed = try await restarted.list(now: later)
        #expect(listed.map(\.id) == [created.id])
        let resolved = try await restarted.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: later
        )
        guard case .resolved = resolved.state else {
            Issue.record("keepWaiting must resolve after restart past deadline")
            return
        }
        #expect(resolved.authorizes(Self.fingerprint, identity: Self.identity))
    }

    @Test func staleFingerprintIsRejectedAfterRestart() async throws {
        let root = try isolatedDirectory()
        let writer = PendingApprovalStore(baseDirectory: root)
        let created = try await writer.create(Self.request(id: "stale-1"), now: Self.now)
        _ = try await writer.resolve(
            id: created.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let restarted = PendingApprovalStore(baseDirectory: root)
        let other = ActionFingerprint(rawValue: "shell:git.force-push:origin:other")
        await #expect(throws: PendingApprovalError.fingerprintMismatch) {
            _ = try await restarted.consume(
                id: created.id,
                fingerprint: other,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func subscribeReceivesCreateAndResolve() async throws {
        let store = PendingApprovalStore(baseDirectory: try isolatedDirectory())
        let stream = await store.events()
        var iterator = stream.makeAsyncIterator()
        let created = try await store.create(Self.request(id: "sub-1"), now: Self.now)
        let createdEvent = await iterator.next()
        #expect(createdEvent == .created(created))
        let resolved = try await store.resolve(
            id: created.id,
            decision: .deny,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let resolvedEvent = await iterator.next()
        #expect(resolvedEvent == .resolved(resolved))
    }

    @Test func storeFilesAreOwnerOnlyAndUninstallListsThem() async throws {
        let store = PendingApprovalStore(baseDirectory: try isolatedDirectory())
        _ = try await store.create(Self.request(id: "perms-1"), now: Self.now)
        let file = RVPolicyPaths.pendingApprovalsFile(inConfigDir: store.baseDirectory)
        let lock = RVPolicyPaths.pendingApprovalsLockFile(inConfigDir: store.baseDirectory)
        #expect(try posixMode(store.baseDirectory) == 0o700)
        #expect(try posixMode(file) == 0o600)
        #expect(try posixMode(lock) == 0o600)

        let names = RVPolicyPaths.uninstallArtifacts(inConfigDir: store.baseDirectory)
            .map(\.lastPathComponent)
        #expect(names.contains("pending-approvals.jsonl"))
        #expect(names.contains(".pending-approvals.lock"))
    }

    @Test func liveUsesConfigDirectoryUnderHome() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-home-\(UUID().uuidString)"))
        let store = PendingApprovalStore.live(home: home)
        #expect(store.baseDirectory == RVPolicyPaths.configDirectory(home: home))
    }

    @Test func corruptJSONLLineIsSkipped() async throws {
        let root = try isolatedDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let junk = "{not-json}\n"
        try junk.write(
            to: RVPolicyPaths.pendingApprovalsFile(inConfigDir: root),
            atomically: true,
            encoding: .utf8
        )
        let store = PendingApprovalStore(baseDirectory: root)
        let created = try await store.create(Self.request(id: "after-junk"), now: Self.now)
        #expect(created.id.rawValue == "after-junk")
        let listed = try await store.list(now: Self.now)
        #expect(listed.map(\.id) == [created.id])
    }
}

private enum StoreOp: Equatable {
    case success
    case alreadyResolved
    case alreadyConsumed
    case other

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func resultOf(_ body: () async throws -> PendingApproval) async -> StoreOp {
    do {
        _ = try await body()
        return .success
    } catch PendingApprovalError.alreadyResolved {
        return .alreadyResolved
    } catch {
        return .other
    }
}

private func consumeResult(
    _ store: PendingApprovalStore,
    id: ApprovalID
) async -> StoreOp {
    do {
        _ = try await store.consume(
            id: id,
            fingerprint: PendingApprovalStoreTests.fingerprint,
            identity: PendingApprovalStoreTests.identity,
            now: PendingApprovalStoreTests.now
        )
        return .success
    } catch PendingApprovalError.alreadyConsumed {
        return .alreadyConsumed
    } catch {
        return .other
    }
}

private extension PendingApprovalStoreTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)
    static let fingerprint = ActionFingerprint(rawValue: "shell:git.force-push:origin:main")
    static let identity = ApprovalIdentity(
        session: SessionIdentity(rawValue: "sess-1"),
        agent: AgentIdentity(rawValue: "agent-1")
    )

    static func request(
        id: String,
        timeoutPolicy: ApprovalTimeoutPolicy = .keepWaiting,
        ttl: TimeInterval = 60
    ) -> PendingApprovalRequest {
        PendingApprovalRequest(
            id: ApprovalID(rawValue: id),
            identity: identity,
            action: .shell(
                ShellAction(
                    fingerprint: fingerprint,
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: ActionResources(remoteName: "origin", branchName: "main"),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv"))
                )
            ),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: timeoutPolicy,
            ttl: ttl
        )
    }
}

private func isolatedDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-pending-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let raw = attrs[.posixPermissions] as? NSNumber
    return (raw?.intValue ?? 0) & 0o777
}
