import Foundation
import Testing
import RVDomain

@Suite("PendingApproval ledger")
struct PendingApprovalLedgerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func hostAdapterCreatesWithoutUIState() throws {
        let request = Self.request(id: "ask-1", continuation: .hostNative)
        let (record, records) = try PendingApprovalLedger.create(
            records: [],
            request: request,
            now: Self.now
        )
        #expect(records.count == 1)
        #expect(record.id.rawValue == "ask-1")
        #expect(record.identity == Self.identity)
        #expect(record.fingerprint == Self.fingerprint)
        #expect(record.state == .awaitingHuman)
        #expect(record.consumedAt == nil)
        #expect(record.expiresAt == Self.now.addingTimeInterval(60))
        #expect(record.authorizes(Self.fingerprint, identity: Self.identity) == false)
    }

    @Test func duplicateResolveIsRejected() throws {
        let created = try Self.created()
        let (resolved, afterResolve) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        guard case .resolved(let resolution) = resolved.state else {
            Issue.record("first resolve must record a decision")
            return
        }
        #expect(resolution.decision == .allowOnce)
        #expect(throws: PendingApprovalError.alreadyResolved) {
            _ = try PendingApprovalLedger.resolve(
                records: afterResolve,
                id: created.record.id,
                decision: .deny,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func consumeDeliversResolutionExactlyOnce() throws {
        let created = try Self.created()
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let (first, afterFirst) = try PendingApprovalLedger.consume(
            records: resolved,
            id: created.record.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(first.decision == .allowOnce)
        guard case .consumed(let resolution, let at) = first.approval.state else {
            Issue.record("consume must fold into PendingApprovalState.consumed")
            return
        }
        #expect(resolution.decision == .allowOnce)
        #expect(at == Self.now)
        #expect(first.approval.consumedAt == at)
        #expect(first.approval.authorizes(Self.fingerprint, identity: Self.identity) == false)
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.consume(
                records: afterFirst,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.resolve(
                records: afterFirst,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func denyIsDeliveredOnceAndNeverAuthorizes() throws {
        let created = try Self.created()
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .deny,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(created.record.authorizes(Self.fingerprint, identity: Self.identity) == false)
        let (consumption, after) = try PendingApprovalLedger.consume(
            records: resolved,
            id: created.record.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(consumption.decision == .deny)
        #expect(consumption.decision.authorizesExactAction == false)
        guard case .consumed(let resolution, _) = consumption.approval.state else {
            Issue.record("deny consume must still be .consumed")
            return
        }
        #expect(resolution.decision == .deny)
        #expect(consumption.approval.authorizes(Self.fingerprint, identity: Self.identity) == false)
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.consume(
                records: after,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func staleFingerprintCannotResolveOrAuthorize() throws {
        let created = try Self.created()
        let other = ActionFingerprint(rawValue: "shell:git.force-push:origin:other")
        #expect(throws: PendingApprovalError.fingerprintMismatch) {
            _ = try PendingApprovalLedger.resolve(
                records: created.records,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: other,
                identity: Self.identity,
                now: Self.now
            )
        }
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(throws: PendingApprovalError.fingerprintMismatch) {
            _ = try PendingApprovalLedger.consume(
                records: resolved,
                id: created.record.id,
                fingerprint: other,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(resolved[0].authorizes(other, identity: Self.identity) == false)
    }

    @Test func approvalForOneFingerprintCannotAuthorizeASiblingAction() throws {
        let first = try Self.created(id: "a", fingerprint: "shell:git.reset:hard")
        let secondRequest = Self.request(
            id: "b",
            fingerprint: "shell:git.reset:mixed"
        )
        let (_, both) = try PendingApprovalLedger.create(
            records: first.records,
            request: secondRequest,
            now: Self.now
        )
        let (_, resolvedA) = try PendingApprovalLedger.resolve(
            records: both,
            id: ApprovalID(rawValue: "a"),
            decision: .allowOnce,
            fingerprint: ActionFingerprint(rawValue: "shell:git.reset:hard"),
            identity: Self.identity,
            now: Self.now
        )
        #expect(throws: PendingApprovalError.fingerprintMismatch) {
            _ = try PendingApprovalLedger.consume(
                records: resolvedA,
                id: ApprovalID(rawValue: "a"),
                fingerprint: ActionFingerprint(rawValue: "shell:git.reset:mixed"),
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(throws: PendingApprovalError.notResolved) {
            _ = try PendingApprovalLedger.consume(
                records: resolvedA,
                id: ApprovalID(rawValue: "b"),
                fingerprint: ActionFingerprint(rawValue: "shell:git.reset:mixed"),
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func replayedIdenticalActionCannotBeConsumedTwice() throws {
        let created = try Self.created()
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .createRule,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let (_, after) = try PendingApprovalLedger.consume(
            records: resolved,
            id: created.record.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.consume(
                records: after,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func cancelBlocksLaterResolveAndConsume() throws {
        let created = try Self.created()
        let (canceled, after) = try PendingApprovalLedger.cancel(
            records: created.records,
            id: created.record.id,
            now: Self.now
        )
        guard case .canceled = canceled.state else {
            Issue.record("cancel must be terminal")
            return
        }
        #expect(throws: PendingApprovalError.canceled) {
            _ = try PendingApprovalLedger.resolve(
                records: after,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(throws: PendingApprovalError.canceled) {
            _ = try PendingApprovalLedger.consume(
                records: after,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(canceled.authorizes(Self.fingerprint, identity: Self.identity) == false)
    }

    @Test func explicitExpireBlocksLaterAuthorization() throws {
        let created = try Self.created()
        let (_, after) = try PendingApprovalLedger.expire(
            records: created.records,
            id: created.record.id,
            now: Self.now
        )
        #expect(throws: PendingApprovalError.expired) {
            _ = try PendingApprovalLedger.resolve(
                records: after,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(throws: PendingApprovalError.expired) {
            _ = try PendingApprovalLedger.consume(
                records: after,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func autoDenyTimeoutCannotLaterAuthorize() throws {
        let created = try Self.created(timeoutPolicy: .autoDeny, ttl: 1)
        let later = Self.now.addingTimeInterval(2)
        #expect(throws: PendingApprovalError.timedOut) {
            _ = try PendingApprovalLedger.resolve(
                records: created.records,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: later
            )
        }
        #expect(throws: PendingApprovalError.timedOut) {
            _ = try PendingApprovalLedger.consume(
                records: created.records,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: later
            )
        }
        let awaiting = PendingApprovalLedger.awaitingHuman(created.records, now: later)
        #expect(awaiting.isEmpty)
    }

    @Test func failTaskTimeoutCannotLaterAuthorize() throws {
        let created = try Self.created(timeoutPolicy: .failTask, ttl: 1)
        let later = Self.now.addingTimeInterval(2)
        let swept = PendingApprovalLedger.sweep(created.records, now: later)
        guard case .timedOut(let ending) = swept[0].state else {
            Issue.record("failTask must time out")
            return
        }
        #expect(ending.policy == .failTask)
        #expect(swept[0].authorizes(Self.fingerprint, identity: Self.identity) == false)
        #expect(throws: PendingApprovalError.timedOut) {
            _ = try PendingApprovalLedger.consume(
                records: created.records,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: later
            )
        }
    }

    @Test func keepWaitingAllowsResolveAfterDeadline() throws {
        let created = try Self.created(timeoutPolicy: .keepWaiting, ttl: 1)
        let later = Self.now.addingTimeInterval(2)
        let awaiting = PendingApprovalLedger.awaitingHuman(created.records, now: later)
        #expect(awaiting.count == 1)
        let (resolved, _) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: later
        )
        guard case .resolved = resolved.state else {
            Issue.record("keepWaiting must still resolve")
            return
        }
        #expect(resolved.authorizes(Self.fingerprint, identity: Self.identity))
    }

    @Test func exactDeadlineIsStillAwaitingHuman() throws {
        let created = try Self.created(timeoutPolicy: .autoDeny, ttl: 10)
        let atDeadline = created.record.expiresAt
        let awaiting = PendingApprovalLedger.awaitingHuman(created.records, now: atDeadline)
        #expect(awaiting.count == 1)
        let (resolved, _) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: atDeadline
        )
        guard case .resolved = resolved.state else {
            Issue.record("expiresAt == now must still resolve")
            return
        }
        #expect(resolved.authorizes(Self.fingerprint, identity: Self.identity))
    }

    @Test func identityMismatchCannotResolveOrConsume() throws {
        let created = try Self.created()
        let other = ApprovalIdentity(
            session: SessionIdentity(rawValue: "sess-other"),
            agent: AgentIdentity(rawValue: "agent-1")
        )
        #expect(throws: PendingApprovalError.identityMismatch) {
            _ = try PendingApprovalLedger.resolve(
                records: created.records,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: other,
                now: Self.now
            )
        }
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        #expect(throws: PendingApprovalError.identityMismatch) {
            _ = try PendingApprovalLedger.consume(
                records: resolved,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: other,
                now: Self.now
            )
        }
    }

    @Test func retryContinuationMustMatchActionFingerprint() {
        let request = Self.request(
            continuation: .retry(ActionFingerprint(rawValue: "shell:other"))
        )
        #expect(throws: PendingApprovalError.continuationMismatch) {
            _ = try PendingApprovalLedger.create(records: [], request: request, now: Self.now)
        }
    }

    @Test func resumeAndRetryContinuationsRoundTrip() throws {
        let (resume, _) = try PendingApprovalLedger.create(
            records: [],
            request: Self.request(
                id: "resume",
                continuation: .resume(ApprovalResumeToken(rawValue: "tok-1"))
            ),
            now: Self.now
        )
        let (retry, _) = try PendingApprovalLedger.create(
            records: [],
            request: Self.request(
                id: "retry",
                continuation: .retry(Self.fingerprint)
            ),
            now: Self.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let resumeData = try encoder.encode(resume)
        let retryData = try encoder.encode(retry)
        #expect(try decoder.decode(PendingApproval.self, from: resumeData) == resume)
        #expect(try decoder.decode(PendingApproval.self, from: retryData) == retry)
        #expect(resume.continuation == .resume(ApprovalResumeToken(rawValue: "tok-1")))
        #expect(retry.continuation == .retry(Self.fingerprint))
    }

    @Test func awaitingHumanCannotCarryAParallelConsumedAt() throws {
        let created = try Self.created()
        #expect(created.record.state == .awaitingHuman)
        #expect(created.record.consumedAt == nil)
        #expect(created.record.authorizes(Self.fingerprint, identity: Self.identity) == false)
        #expect(throws: PendingApprovalError.notResolved) {
            _ = try PendingApprovalLedger.consume(
                records: created.records,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test(arguments: [ApprovalDecision.allowOnce, .createRule, .deny])
    func consumeFoldsEachDecisionIntoConsumedState(decision: ApprovalDecision) throws {
        let created = try Self.created()
        let (resolved, afterResolve) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: decision,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        guard case .resolved = resolved.state else {
            Issue.record("resolve must leave an unconsumed authorizing-or-deny resolution")
            return
        }
        #expect(resolved.consumedAt == nil)
        let (consumption, afterConsume) = try PendingApprovalLedger.consume(
            records: afterResolve,
            id: created.record.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        guard case .consumed(let resolution, let at) = consumption.approval.state else {
            Issue.record("consume must transition .resolved → .consumed")
            return
        }
        #expect(resolution.decision == decision)
        #expect(at == Self.now)
        #expect(consumption.approval.consumedAt == at)
        #expect(consumption.approval.authorizes(Self.fingerprint, identity: Self.identity) == false)
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.consume(
                records: afterConsume,
                id: created.record.id,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
        #expect(throws: PendingApprovalError.alreadyConsumed) {
            _ = try PendingApprovalLedger.resolve(
                records: afterConsume,
                id: created.record.id,
                decision: .allowOnce,
                fingerprint: Self.fingerprint,
                identity: Self.identity,
                now: Self.now
            )
        }
    }

    @Test func consumedStateRoundTripsThroughCodable() throws {
        let created = try Self.created()
        let (_, resolved) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let (consumption, _) = try PendingApprovalLedger.consume(
            records: resolved,
            id: created.record.id,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(consumption.approval)
        let decoded = try decoder.decode(PendingApproval.self, from: data)
        #expect(decoded == consumption.approval)
        guard case .consumed = decoded.state else {
            Issue.record("new encodes must use PendingApprovalState.consumed")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try #require(object["state"] as? [String: Any])
        #expect(state["kind"] as? String == "consumed")
        #expect(object["consumedAt"] == nil)
    }

    @Test func decodeMigratesResolvedPlusParentConsumedAt() throws {
        let created = try Self.created()
        let (resolved, _) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .createRule,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        guard case .resolved(let resolution) = resolved.state else {
            Issue.record("fixture must start as unconsumed .resolved")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoded = try encoder.encode(resolved)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let stamp = try encoder.encode(LegacyConsumedAtStamp(consumedAt: Self.now))
        let stampObject = try #require(try JSONSerialization.jsonObject(with: stamp) as? [String: Any])
        object["consumedAt"] = stampObject["consumedAt"]
        let state = try #require(object["state"] as? [String: Any])
        #expect(state["kind"] as? String == "resolved")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try decoder.decode(PendingApproval.self, from: legacy)
        guard case .consumed(let migrated, let at) = decoded.state else {
            Issue.record("resolved + parent consumedAt must decode as .consumed")
            return
        }
        #expect(migrated == resolution)
        #expect(at == Self.now)
        #expect(decoded.consumedAt == at)
        #expect(decoded.authorizes(Self.fingerprint, identity: Self.identity) == false)
    }

    @Test func resolvedWithoutParentConsumedAtStaysResolved() throws {
        let created = try Self.created()
        let (resolved, _) = try PendingApprovalLedger.resolve(
            records: created.records,
            id: created.record.id,
            decision: .allowOnce,
            fingerprint: Self.fingerprint,
            identity: Self.identity,
            now: Self.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PendingApproval.self, from: encoder.encode(resolved))
        guard case .resolved = decoded.state else {
            Issue.record("unconsumed resolved JSON must stay .resolved")
            return
        }
        #expect(decoded.consumedAt == nil)
        #expect(decoded.authorizes(Self.fingerprint, identity: Self.identity))
        #expect(decoded == resolved)
    }

    @Test func emptyIdentityOrTTLIsRejected() {
        let emptyIdentity = PendingApprovalRequest(
            id: ApprovalID(rawValue: "ask"),
            identity: ApprovalIdentity(
                session: SessionIdentity(rawValue: ""),
                agent: AgentIdentity(rawValue: "agent-1")
            ),
            action: Self.action(),
            reason: .hostAsk,
            continuation: .hostNative,
            timeoutPolicy: .autoDeny,
            ttl: 60
        )
        #expect(throws: PendingApprovalError.invalidRequest) {
            _ = try PendingApprovalLedger.create(records: [], request: emptyIdentity, now: Self.now)
        }
        #expect(throws: PendingApprovalError.invalidRequest) {
            _ = try PendingApprovalLedger.create(
                records: [],
                request: Self.request(ttl: 0),
                now: Self.now
            )
        }
    }

    @Test func duplicateIDCannotAuthorizeANewAction() throws {
        let first = try Self.created(id: "same")
        let replay = Self.request(
            id: "same",
            fingerprint: "shell:git.reset:mixed"
        )
        #expect(throws: PendingApprovalError.duplicateID) {
            _ = try PendingApprovalLedger.create(
                records: first.records,
                request: replay,
                now: Self.now
            )
        }
    }
}

private extension PendingApprovalLedgerTests {
    static let fingerprint = ActionFingerprint(rawValue: "shell:git.force-push:origin:main")
    static let identity = ApprovalIdentity(
        session: SessionIdentity(rawValue: "sess-1"),
        agent: AgentIdentity(rawValue: "agent-1")
    )

    static func action(fingerprint: String = "shell:git.force-push:origin:main") -> ProposedAction {
        .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: fingerprint),
                effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                resources: ActionResources(remoteName: "origin", branchName: "main"),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv"))
            )
        )
    }

    static func request(
        id: String = "ask-1",
        fingerprint: String = "shell:git.force-push:origin:main",
        continuation: ApprovalContinuation = .hostNative,
        timeoutPolicy: ApprovalTimeoutPolicy = .autoDeny,
        ttl: TimeInterval = 60
    ) -> PendingApprovalRequest {
        PendingApprovalRequest(
            id: ApprovalID(rawValue: id),
            identity: identity,
            action: action(fingerprint: fingerprint),
            reason: .mandatoryHuman,
            continuation: continuation,
            timeoutPolicy: timeoutPolicy,
            ttl: ttl
        )
    }

    static func created(
        id: String = "ask-1",
        fingerprint: String = "shell:git.force-push:origin:main",
        timeoutPolicy: ApprovalTimeoutPolicy = .autoDeny,
        ttl: TimeInterval = 60
    ) throws -> (record: PendingApproval, records: [PendingApproval]) {
        try PendingApprovalLedger.create(
            records: [],
            request: request(
                id: id,
                fingerprint: fingerprint,
                timeoutPolicy: timeoutPolicy,
                ttl: ttl
            ),
            now: now
        )
    }
}

private struct LegacyConsumedAtStamp: Encodable {
    var consumedAt: Date
}
