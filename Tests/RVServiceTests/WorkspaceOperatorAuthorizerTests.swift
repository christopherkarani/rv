import Foundation
import RVDomain
import Synchronization
import Testing
@testable import RVIsolation
@testable import RVService

/// Step 3: service-owned challenge/permit state machine.
///
/// Every test drives the authorizer actor directly with a controllable clock.
/// Fixtures are trusted internal constructions (future production bindings
/// arrive over authenticated host/service paths); the suite proves the state
/// machine binds, expires, invalidates, and consumes exactly once — and that
/// none of it can launch, spawn, or mint capabilities.
@Suite("Workspace operator authorization")
struct WorkspaceOperatorAuthorizerTests {
    // MARK: - Seams

    private final class TestClock: Sendable {
        private let values: Mutex<(date: Date, instant: ContinuousClock.Instant)>

        init() {
            values = Mutex((date: Date(), instant: ContinuousClock.now))
        }

        func wallNow() -> Date { values.withLock { $0.date } }
        func monotonicNow() -> ContinuousClock.Instant { values.withLock { $0.instant } }
        func setInstant(_ instant: ContinuousClock.Instant) {
            values.withLock { $0.instant = instant }
        }
        func advanceMonotonic(by duration: Duration) {
            values.withLock { $0.instant = $0.instant.advanced(by: duration) }
        }
        func advanceWall(by interval: TimeInterval) {
            values.withLock { $0.date = $0.date.addingTimeInterval(interval) }
        }
    }

    private final class AuditRecorder: Sendable {
        private let events = Mutex<[WorkspaceOperatorAuthorizationAuditEvent]>([])

        func record(_ event: WorkspaceOperatorAuthorizationAuditEvent) {
            events.withLock { $0.append(event) }
        }

        var all: [WorkspaceOperatorAuthorizationAuditEvent] {
            events.withLock { $0 }
        }

        var kinds: [WorkspaceOperatorAuthorizationAuditEvent.Kind] {
            all.map(\.kind)
        }

        func count(of kind: WorkspaceOperatorAuthorizationAuditEvent.Kind) -> Int {
            all.filter { $0.kind == kind }.count
        }
    }

    private struct Fixture: Sendable {
        static let matchingDigest = String(repeating: "a", count: 64)
        static let otherDigest = String(repeating: "b", count: 64)

        let requester: WorkspaceAuthorizationRequester
        let clientRequestID: UUID?
        let workspace: WorkspaceSessionID
        let host: WorkspaceHostID
        let generation: WorkspaceHostGeneration
        let registration: WorkspaceHostRegistrationBinding
        let preparedLaunch: PreparedLaunchID
        let intentDigest: WorkspaceLaunchIntentDigest
        let kind: WorkspaceOperationKind
        let definition: WorkspaceOperationDefinitionBinding?

        init(
            kind: WorkspaceOperationKind = .launchAgent,
            digestHex: String = Fixture.matchingDigest,
            clientRequestID: UUID? = nil
        ) {
            let host = WorkspaceHostID()
            let generation = WorkspaceHostGeneration()
            self.requester = WorkspaceAuthorizationRequester(
                connectionID: UUID(), componentRole: .cli)
            self.clientRequestID = clientRequestID
            self.workspace = WorkspaceSessionID()
            self.host = host
            self.generation = generation
            self.registration = WorkspaceHostRegistrationBinding(
                host: host, generation: generation, connectionID: UUID())
            self.preparedLaunch = PreparedLaunchID()
            self.intentDigest = WorkspaceLaunchIntentDigest(sha256Hex: digestHex)
            self.kind = kind
            switch kind {
            case .launchAgent:
                self.definition = WorkspaceOperationDefinitionBinding(
                    definitionID: AgentDefinitionID(rawValue: "test-agent"),
                    revision: AgentDefinitionRevision(digestHex: String(repeating: "c", count: 64)))
            case .launchCustom:
                self.definition = nil
            }
        }

        func expectation() -> WorkspaceOperationRedemptionExpectation {
            WorkspaceOperationRedemptionExpectation(
                workspace: workspace,
                host: host,
                generation: generation,
                registration: registration,
                preparedLaunch: preparedLaunch,
                intentDigest: intentDigest,
                kind: kind,
                definition: definition)
        }
    }

    private func authorizer(
        clock: TestClock,
        recorder: AuditRecorder? = nil
    ) -> WorkspaceOperatorAuthorizer {
        let sink: (@Sendable (WorkspaceOperatorAuthorizationAuditEvent) -> Void)?
        if let recorder {
            sink = { recorder.record($0) }
        } else {
            sink = nil
        }
        return WorkspaceOperatorAuthorizer(
            clock: { clock.wallNow() },
            monotonicNow: { clock.monotonicNow() },
            audit: sink)
    }

    private func create(
        _ auth: WorkspaceOperatorAuthorizer,
        _ fx: Fixture
    ) async throws -> WorkspaceOperationAuthorizationReference {
        try await auth.createOperation(
            requester: fx.requester,
            clientRequestID: fx.clientRequestID,
            workspace: fx.workspace,
            host: fx.host,
            generation: fx.generation,
            registration: fx.registration,
            preparedLaunch: fx.preparedLaunch,
            intentDigest: fx.intentDigest,
            kind: fx.kind,
            definition: fx.definition)
    }

    private func driveToPermit(
        _ auth: WorkspaceOperatorAuthorizer,
        _ fx: Fixture,
        uiConnection: AuthenticatedOperatorUIConnectionID = AuthenticatedOperatorUIConnectionID()
    ) async throws -> (WorkspaceOperationAuthorizationReference, OperatorAuthorizationChallenge) {
        let ref = try await create(auth, fx)
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: uiConnection)
        let permitRef = try await auth.completeChallenge(
            challenge, uiConnection: uiConnection, result: .authenticated)
        #expect(permitRef == ref)
        return (ref, challenge)
    }

    // MARK: - Base lifecycle

    @Test func fullLifecycleConsumesOnceAndBurns() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()

        let ref = try await create(auth, fx)
        #expect(try await auth.status(of: ref.authorizationID) == .pending)

        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        #expect(try await auth.status(of: ref.authorizationID) == .awaitingAuthentication)

        let permitRef = try await auth.completeChallenge(
            challenge, uiConnection: ui, result: .authenticated)
        #expect(permitRef == ref)
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)

        let redemption = try await auth.consumePermit(ref, expectation: fx.expectation())
        #expect(redemption.authorizationID == ref.authorizationID)
        let epoch = await auth.epoch
        #expect(redemption.epoch == epoch)
        #expect(redemption.workspace == fx.workspace)
        #expect(redemption.host == fx.host)
        #expect(redemption.generation == fx.generation)
        #expect(redemption.registration == fx.registration)
        #expect(redemption.preparedLaunch == fx.preparedLaunch)
        #expect(redemption.kind == fx.kind)
        #expect(redemption.intentDigest == fx.intentDigest)
        #expect(redemption.definition == fx.definition)
        #expect(redemption.challengeID == challenge.id)
        #expect(redemption.uiConnection == ui)
        #expect(redemption.actor == OperatorAuthorizationActor(
            mechanism: .deviceOwnerAuthentication, uiConnection: ui))
        #expect(try await auth.status(of: ref.authorizationID) == .consumed)

        await #expect(throws: WorkspaceOperatorAuthorizationError.consumed) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
        #expect(try await auth.status(of: ref.authorizationID) == .consumed)
    }

    @Test func customLaunchLifecycleNeedsNoDefinition() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture(kind: .launchCustom)
        let (ref, _) = try await driveToPermit(auth, fx)
        let redemption = try await auth.consumePermit(ref, expectation: fx.expectation())
        #expect(redemption.kind == .launchCustom)
        #expect(redemption.definition == nil)
    }

    // MARK: - Creation validation

    @Test func namedLaunchRequiresDefinition() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture(kind: .launchAgent)
        await #expect(throws: WorkspaceOperatorAuthorizationError.invalidRequest) {
            try await auth.createOperation(
                requester: fx.requester, clientRequestID: nil, workspace: fx.workspace,
                host: fx.host, generation: fx.generation, registration: fx.registration,
                preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest,
                kind: .launchAgent, definition: nil)
        }
    }

    @Test func customLaunchForbidsDefinition() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture(kind: .launchCustom)
        let rogue = WorkspaceOperationDefinitionBinding(
            definitionID: AgentDefinitionID(rawValue: "smuggled"),
            revision: AgentDefinitionRevision(digestHex: String(repeating: "d", count: 64)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.invalidRequest) {
            try await auth.createOperation(
                requester: fx.requester, clientRequestID: nil, workspace: fx.workspace,
                host: fx.host, generation: fx.generation, registration: fx.registration,
                preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest,
                kind: .launchCustom, definition: rogue)
        }
    }

    @Test func inconsistentRegistrationBindingRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let skewed = WorkspaceHostRegistrationBinding(
            host: WorkspaceHostID(), generation: fx.generation, connectionID: UUID())
        await #expect(throws: WorkspaceOperatorAuthorizationError.invalidRequest) {
            try await auth.createOperation(
                requester: fx.requester, clientRequestID: nil, workspace: fx.workspace,
                host: fx.host, generation: fx.generation, registration: skewed,
                preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest,
                kind: fx.kind, definition: fx.definition)
        }
    }

    // MARK: - Invalid transitions

    @Test func completionBeforeIssuanceRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let forged = OperatorAuthorizationChallenge(
            id: OperatorAuthorizationChallengeID(), epoch: await auth.epoch,
            operationID: ref.authorizationID, workspace: fx.workspace, host: fx.host,
            generation: fx.generation, registration: fx.registration,
            preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest, kind: fx.kind,
            uiConnection: ui, issuedWall: clock.wallNow(),
            deadlineMono: clock.monotonicNow().advanced(by: .seconds(60)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.completeChallenge(forged, uiConnection: ui, result: .authenticated)
        }
        let unknown = OperatorAuthorizationChallenge(
            id: OperatorAuthorizationChallengeID(), epoch: await auth.epoch,
            operationID: WorkspaceOperationAuthorizationID(), workspace: fx.workspace,
            host: fx.host, generation: fx.generation, registration: fx.registration,
            preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest, kind: fx.kind,
            uiConnection: ui, issuedWall: clock.wallNow(),
            deadlineMono: clock.monotonicNow().advanced(by: .seconds(60)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.unknownOperation) {
            try await auth.completeChallenge(unknown, uiConnection: ui, result: .authenticated)
        }
    }

    @Test func secondChallengeRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        _ = try await auth.issueChallenge(
            operationID: ref.authorizationID,
            uiConnection: AuthenticatedOperatorUIConnectionID())
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.issueChallenge(
                operationID: ref.authorizationID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func cancelledOperationRejectsEverything() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        try await auth.cancel(operationID: ref.authorizationID)
        #expect(try await auth.status(of: ref.authorizationID) == .cancelled)
        let ui = AuthenticatedOperatorUIConnectionID()
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.issueChallenge(operationID: ref.authorizationID, uiConnection: ui)
        }
        let forged = OperatorAuthorizationChallenge(
            id: OperatorAuthorizationChallengeID(), epoch: await auth.epoch,
            operationID: ref.authorizationID, workspace: fx.workspace, host: fx.host,
            generation: fx.generation, registration: fx.registration,
            preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest, kind: fx.kind,
            uiConnection: ui, issuedWall: clock.wallNow(),
            deadlineMono: clock.monotonicNow().advanced(by: .seconds(60)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.completeChallenge(forged, uiConnection: ui, result: .authenticated)
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.cancel(operationID: ref.authorizationID)
        }
    }

    @Test func duplicateCompletionRejectsAndMintsOnePermit() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        _ = try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        }
        #expect(recorder.count(of: .permitIssued) == 1)
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)
    }

    @Test func consumeBeforeAuthorizationRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let pending = Fixture()
        let pendingRef = try await create(auth, pending)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(pendingRef, expectation: pending.expectation())
        }
        let challenged = Fixture()
        let challengedRef = try await create(auth, challenged)
        _ = try await auth.issueChallenge(
            operationID: challengedRef.authorizationID,
            uiConnection: AuthenticatedOperatorUIConnectionID())
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(challengedRef, expectation: challenged.expectation())
        }
    }

    @Test func failedAuthenticationLandsFailedTerminal() async throws {
        for result in [
            OperatorAuthenticationResult.cancelled,
            .unavailable,
            .failed,
        ] {
            let clock = TestClock()
            let auth = authorizer(clock: clock)
            let fx = Fixture()
            let ref = try await create(auth, fx)
            let ui = AuthenticatedOperatorUIConnectionID()
            let challenge = try await auth.issueChallenge(
                operationID: ref.authorizationID, uiConnection: ui)
            await #expect(throws: WorkspaceOperatorAuthorizationError.authenticationFailed) {
                try await auth.completeChallenge(challenge, uiConnection: ui, result: result)
            }
            #expect(try await auth.status(of: ref.authorizationID) == .failed)
            await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
                try await auth.issueChallenge(operationID: ref.authorizationID, uiConnection: ui)
            }
            await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
                try await auth.consumePermit(ref, expectation: fx.expectation())
            }
        }
    }

    @Test func consumedOperationRejectsCancel() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.cancel(operationID: ref.authorizationID)
        }
    }

    @Test func expiredOperationRejectsEveryEntry() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        clock.advanceMonotonic(by: .seconds(121))
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.cancel(operationID: ref.authorizationID)
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.issueChallenge(operationID: ref.authorizationID, uiConnection: ui)
        }
        #expect(try await auth.status(of: ref.authorizationID) == .expired)
    }

    @Test func cancelAfterIssuanceBurnsPermit() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        try await auth.cancel(operationID: ref.authorizationID)
        #expect(try await auth.status(of: ref.authorizationID) == .invalidated)
        #expect(recorder.count(of: .permitInvalidated) == 1)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
    }

    // MARK: - Binding mismatches

    @Test func completionWrongUIConnectionRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID,
            uiConnection: AuthenticatedOperatorUIConnectionID())
        await #expect(throws: WorkspaceOperatorAuthorizationError.bindingMismatch) {
            try await auth.completeChallenge(
                challenge,
                uiConnection: AuthenticatedOperatorUIConnectionID(),
                result: .authenticated)
        }
        #expect(try await auth.status(of: ref.authorizationID) == .awaitingAuthentication)
    }

    @Test func completionForeignEpochRejects() async throws {
        let clockA = TestClock()
        let clockB = TestClock()
        let authA = authorizer(clock: clockA)
        let authB = authorizer(clock: clockB)
        let fx = Fixture()
        let refA = try await create(authA, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challengeA = try await authA.issueChallenge(
            operationID: refA.authorizationID, uiConnection: ui)
        let epochA = await authA.epoch
        let epochB = await authB.epoch
        #expect(epochA != epochB)
        await #expect(throws: WorkspaceOperatorAuthorizationError.wrongEpoch) {
            try await authB.completeChallenge(challengeA, uiConnection: ui, result: .authenticated)
        }
    }

    @Test func completionSubstitutedChallengeRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        let tampered = OperatorAuthorizationChallenge(
            id: challenge.id, epoch: challenge.epoch, operationID: challenge.operationID,
            workspace: challenge.workspace, host: challenge.host,
            generation: challenge.generation, registration: challenge.registration,
            preparedLaunch: challenge.preparedLaunch,
            intentDigest: WorkspaceLaunchIntentDigest(sha256Hex: Fixture.otherDigest),
            kind: challenge.kind, uiConnection: ui, issuedWall: challenge.issuedWall,
            deadlineMono: challenge.deadlineMono)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.completeChallenge(tampered, uiConnection: ui, result: .authenticated)
        }
        #expect(try await auth.status(of: ref.authorizationID) == .awaitingAuthentication)
    }

    @Test func consumeBindingMismatchesRejectOneAtATime() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        let base = fx.expectation()
        let probes: [WorkspaceOperationRedemptionExpectation] = [
            WorkspaceOperationRedemptionExpectation(
                workspace: WorkspaceSessionID(), host: base.host, generation: base.generation,
                registration: base.registration, preparedLaunch: base.preparedLaunch,
                intentDigest: base.intentDigest, kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: WorkspaceHostID(),
                generation: base.generation, registration: base.registration,
                preparedLaunch: base.preparedLaunch, intentDigest: base.intentDigest,
                kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host,
                generation: WorkspaceHostGeneration(), registration: base.registration,
                preparedLaunch: base.preparedLaunch, intentDigest: base.intentDigest,
                kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host, generation: base.generation,
                registration: WorkspaceHostRegistrationBinding(
                    host: base.host, generation: base.generation, connectionID: UUID()),
                preparedLaunch: base.preparedLaunch, intentDigest: base.intentDigest,
                kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host, generation: base.generation,
                registration: base.registration, preparedLaunch: PreparedLaunchID(),
                intentDigest: base.intentDigest, kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host, generation: base.generation,
                registration: base.registration, preparedLaunch: base.preparedLaunch,
                intentDigest: WorkspaceLaunchIntentDigest(sha256Hex: Fixture.otherDigest),
                kind: base.kind, definition: base.definition),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host, generation: base.generation,
                registration: base.registration, preparedLaunch: base.preparedLaunch,
                intentDigest: base.intentDigest, kind: .launchCustom, definition: nil),
            WorkspaceOperationRedemptionExpectation(
                workspace: base.workspace, host: base.host, generation: base.generation,
                registration: base.registration, preparedLaunch: base.preparedLaunch,
                intentDigest: base.intentDigest, kind: base.kind,
                definition: WorkspaceOperationDefinitionBinding(
                    definitionID: AgentDefinitionID(rawValue: "other-agent"),
                    revision: AgentDefinitionRevision(
                        digestHex: String(repeating: "d", count: 64)))),
        ]
        #expect(probes.count == 8)
        for probe in probes {
            await #expect(throws: WorkspaceOperatorAuthorizationError.bindingMismatch) {
                try await auth.consumePermit(ref, expectation: probe)
            }
        }
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)
        _ = try await auth.consumePermit(ref, expectation: base)
        #expect(try await auth.status(of: ref.authorizationID) == .consumed)
    }

    @Test func consumeForeignEpochAndUnknownReject() async throws {
        let clockA = TestClock()
        let clockB = TestClock()
        let authA = authorizer(clock: clockA)
        let authB = authorizer(clock: clockB)
        let fx = Fixture()
        let (refA, _) = try await driveToPermit(authA, fx)
        await #expect(throws: WorkspaceOperatorAuthorizationError.wrongEpoch) {
            try await authB.consumePermit(refA, expectation: fx.expectation())
        }
        let unknown = WorkspaceOperationAuthorizationReference(
            authorizationID: WorkspaceOperationAuthorizationID(), epoch: await authA.epoch)
        await #expect(throws: WorkspaceOperatorAuthorizationError.unknownOperation) {
            try await authA.consumePermit(unknown, expectation: fx.expectation())
        }
    }

    @Test func crossOperationExpectationRejects() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fxA = Fixture()
        let fxB = Fixture()
        let (refA, _) = try await driveToPermit(auth, fxA)
        let (refB, _) = try await driveToPermit(auth, fxB)
        await #expect(throws: WorkspaceOperatorAuthorizationError.bindingMismatch) {
            try await auth.consumePermit(refA, expectation: fxB.expectation())
        }
        _ = try await auth.consumePermit(refA, expectation: fxA.expectation())
        _ = try await auth.consumePermit(refB, expectation: fxB.expectation())
    }

    @Test func definitionMismatchRejects() async throws {
        // Step 5 M1: definition binding is authoritative at consume time.
        // Same prepared launch + digest under a different definition spelling
        // must reject, preventing R1-vs-R2 substitution after review.
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let altDefinition = WorkspaceOperationDefinitionBinding(
            definitionID: AgentDefinitionID(rawValue: "renamed-agent"),
            revision: AgentDefinitionRevision(digestHex: String(repeating: "e", count: 64)))
        let ref = try await auth.createOperation(
            requester: fx.requester, clientRequestID: nil, workspace: fx.workspace,
            host: fx.host, generation: fx.generation, registration: fx.registration,
            preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest,
            kind: .launchAgent, definition: altDefinition)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        _ = try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        await #expect(throws: WorkspaceOperatorAuthorizationError.bindingMismatch) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
    }

    // MARK: - Concurrency (deterministic; no sleeps)

    @Test func concurrentConsumeHasExactlyOneWinner() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        let expectation = fx.expectation()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await auth.consumePermit(ref, expectation: expectation)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(winners == 1)
        #expect(try await auth.status(of: ref.authorizationID) == .consumed)
    }

    @Test func concurrentConsumeLosersSeeConsumed() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        let expectation = fx.expectation()
        let outcomes = await withTaskGroup(
            of: WorkspaceOperatorAuthorizationError?.self,
            returning: [WorkspaceOperatorAuthorizationError?].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        _ = try await auth.consumePermit(ref, expectation: expectation)
                        return nil
                    } catch let error as WorkspaceOperatorAuthorizationError {
                        return error
                    } catch {
                        Issue.record("unexpected error \(error)")
                        return nil
                    }
                }
            }
            var collected: [WorkspaceOperatorAuthorizationError?] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }
        #expect(outcomes.filter { $0 == nil }.count == 1)
        #expect(outcomes.filter { $0 == .consumed }.count == 7)
    }

    @Test func cancelVersusSuccessIsCoherent() async throws {
        for _ in 0..<25 {
            let clock = TestClock()
            let recorder = AuditRecorder()
            let auth = authorizer(clock: clock, recorder: recorder)
            let fx = Fixture()
            let ref = try await create(auth, fx)
            let ui = AuthenticatedOperatorUIConnectionID()
            let challenge = try await auth.issueChallenge(
                operationID: ref.authorizationID, uiConnection: ui)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try? await auth.completeChallenge(
                        challenge, uiConnection: ui, result: .authenticated)
                }
                group.addTask {
                    _ = try? await auth.cancel(operationID: ref.authorizationID)
                }
            }
            let status = try await auth.status(of: ref.authorizationID)
            #expect(status == .cancelled || status == .invalidated)
            #expect(recorder.count(of: .permitIssued) <= 1)
            await #expect(throws: WorkspaceOperatorAuthorizationError.self) {
                try await auth.consumePermit(ref, expectation: fx.expectation())
            }
        }
    }

    @Test func hostDisconnectVersusConsumeIsCoherent() async throws {
        for _ in 0..<25 {
            let clock = TestClock()
            let auth = authorizer(clock: clock)
            let fx = Fixture()
            let (ref, _) = try await driveToPermit(auth, fx)
            let expectation = fx.expectation()
            let consumed = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    (try? await auth.consumePermit(ref, expectation: expectation)) != nil
                }
                group.addTask {
                    await auth.hostDisconnected(connectionID: fx.registration.connectionID)
                    return false
                }
                var won = false
                for await outcome in group { won = won || outcome }
                return won
            }
            let status = try await auth.status(of: ref.authorizationID)
            if consumed {
                #expect(status == .consumed)
            } else {
                #expect(status == .invalidated)
            }
        }
    }

    @Test func hostDisconnectBeforeConsumeInvalidates() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        await auth.hostDisconnected(connectionID: fx.registration.connectionID)
        #expect(try await auth.status(of: ref.authorizationID) == .invalidated)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
    }

    @Test func hostDisconnectAfterConsumeKeepsConsumed() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())
        await auth.hostDisconnected(connectionID: fx.registration.connectionID)
        #expect(try await auth.status(of: ref.authorizationID) == .consumed)
        await #expect(throws: WorkspaceOperatorAuthorizationError.consumed) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
    }

    @Test func uiDisconnectBeforeConsumeInvalidatesCeremony() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        let challenged = Fixture()
        let challengedRef = try await create(auth, challenged)
        let challengedUI = AuthenticatedOperatorUIConnectionID()
        let challengedChallenge = try await auth.issueChallenge(
            operationID: challengedRef.authorizationID, uiConnection: challengedUI)
        let pending = Fixture()
        let pendingRef = try await create(auth, pending)

        await auth.uiDisconnected(challengedUI)
        #expect(try await auth.status(of: challengedRef.authorizationID) == .invalidated)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.completeChallenge(
                challengedChallenge, uiConnection: challengedUI, result: .authenticated)
        }
        // The authorized ceremony used a different UI connection: still live.
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)
        // Pending operations have no UI binding yet: untouched.
        #expect(try await auth.status(of: pendingRef.authorizationID) == .pending)
        #expect(recorder.count(of: .operationInvalidated) == 1)
    }

    @Test func uiDisconnectBurnsIssuedPermit() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let ui = AuthenticatedOperatorUIConnectionID()
        let (ref, _) = try await driveToPermit(auth, fx, uiConnection: ui)
        await auth.uiDisconnected(ui)
        #expect(try await auth.status(of: ref.authorizationID) == .invalidated)
        #expect(recorder.count(of: .permitInvalidated) == 1)
        await #expect(throws: WorkspaceOperatorAuthorizationError.stateMismatch) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }
    }

    // MARK: - Expiry boundaries (now == expiry fails closed)

    @Test func expiryVersusSuccessAtExactBoundary() async throws {
        // At the exact challenge deadline, expiry wins: no permit.
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let start = clock.monotonicNow()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        clock.setInstant(start.advanced(by: .seconds(60)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        }
        #expect(try await auth.status(of: ref.authorizationID) == .expired)

        // One millisecond before the deadline, success wins.
        let earlyClock = TestClock()
        let earlyAuth = authorizer(clock: earlyClock)
        let earlyStart = earlyClock.monotonicNow()
        let earlyFx = Fixture()
        let earlyRef = try await create(earlyAuth, earlyFx)
        let earlyChallenge = try await earlyAuth.issueChallenge(
            operationID: earlyRef.authorizationID, uiConnection: ui)
        earlyClock.setInstant(earlyStart.advanced(by: .seconds(60)).advanced(by: .milliseconds(-1)))
        _ = try await earlyAuth.completeChallenge(
            earlyChallenge, uiConnection: ui, result: .authenticated)
        #expect(try await earlyAuth.status(of: earlyRef.authorizationID) == .authorized)
    }

    @Test func expiryVersusConsumeAtExactBoundary() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let start = clock.monotonicNow()
        let (ref, _) = try await driveToPermit(auth, fx)
        clock.setInstant(start.advanced(by: .seconds(30)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.consumePermit(ref, expectation: fx.expectation())
        }

        let earlyClock = TestClock()
        let earlyAuth = authorizer(clock: earlyClock)
        let earlyStart = earlyClock.monotonicNow()
        let earlyFx = Fixture()
        let (earlyRef, _) = try await driveToPermit(earlyAuth, earlyFx)
        earlyClock.setInstant(earlyStart.advanced(by: .seconds(30)).advanced(by: .milliseconds(-1)))
        _ = try await earlyAuth.consumePermit(earlyRef, expectation: earlyFx.expectation())
        #expect(try await earlyAuth.status(of: earlyRef.authorizationID) == .consumed)
    }

    @Test func exactParentBoundaryFailsClosed() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let start = clock.monotonicNow()
        let ref = try await create(auth, fx)
        clock.setInstant(start.advanced(by: .seconds(120)))
        #expect(try await auth.status(of: ref.authorizationID) == .expired)
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await auth.issueChallenge(
                operationID: ref.authorizationID,
                uiConnection: AuthenticatedOperatorUIConnectionID())
        }
    }

    @Test func childDeadlinesBoundedByParent() async throws {
        // A ceremony starting 100s into the parent lifetime gets no fresh
        // long tail: challenge and permit both die at the parent deadline.
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let start = clock.monotonicNow()
        let ref = try await create(auth, fx)
        clock.setInstant(start.advanced(by: .seconds(100)))
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        _ = try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        clock.setInstant(start.advanced(by: .seconds(119)))
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())

        let lateClock = TestClock()
        let lateAuth = authorizer(clock: lateClock)
        let lateStart = lateClock.monotonicNow()
        let lateFx = Fixture()
        let lateRef = try await create(lateAuth, lateFx)
        lateClock.setInstant(lateStart.advanced(by: .seconds(100)))
        let lateChallenge = try await lateAuth.issueChallenge(
            operationID: lateRef.authorizationID, uiConnection: ui)
        _ = try await lateAuth.completeChallenge(
            lateChallenge, uiConnection: ui, result: .authenticated)
        lateClock.setInstant(lateStart.advanced(by: .seconds(120)))
        await #expect(throws: WorkspaceOperatorAuthorizationError.expired) {
            try await lateAuth.consumePermit(lateRef, expectation: lateFx.expectation())
        }
    }

    @Test func wallClockNeitherExtendsNorRevives() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        clock.advanceWall(by: 3_600)
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())

        let rolled = Fixture()
        let rolledRef = try await create(auth, rolled)
        clock.advanceWall(by: -7_200)
        let ui = AuthenticatedOperatorUIConnectionID()
        _ = try await auth.issueChallenge(operationID: rolledRef.authorizationID, uiConnection: ui)
        #expect(try await auth.status(of: rolledRef.authorizationID) == .awaitingAuthentication)

        // Monotonic advance expires even with the wall clock frozen or rewound.
        clock.advanceMonotonic(by: .seconds(121))
        #expect(try await auth.status(of: rolledRef.authorizationID) == .expired)
    }

    // MARK: - Capacity and cleanup

    @Test func storeRefusesWhenFullAndEvictsExpired() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        for _ in 0..<WorkspaceOperatorAuthorizationLimits.maxOperations {
            _ = try await create(auth, Fixture())
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.storeFull) {
            try await create(auth, Fixture())
        }
        clock.advanceMonotonic(by: .seconds(121))
        _ = try await create(auth, Fixture())
    }

    @Test func duplicateClientRequestIDsDoNotAlias() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let shared = UUID()
        let fxA = Fixture(clientRequestID: shared)
        let fxB = Fixture(clientRequestID: shared)
        let refA = try await create(auth, fxA)
        let refB = try await create(auth, fxB)
        #expect(refA.authorizationID != refB.authorizationID)
        let ui = AuthenticatedOperatorUIConnectionID()
        for (ref, fx) in [(refA, fxA), (refB, fxB)] {
            let challenge = try await auth.issueChallenge(
                operationID: ref.authorizationID, uiConnection: ui)
            _ = try await auth.completeChallenge(
                challenge, uiConnection: ui, result: .authenticated)
            _ = try await auth.consumePermit(ref, expectation: fx.expectation())
        }
        #expect(try await auth.status(of: refA.authorizationID) == .consumed)
        #expect(try await auth.status(of: refB.authorizationID) == .consumed)
    }

    @Test func sweepDropsExpiredTerminalsRetainsConsumed() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let cancelled = Fixture()
        let cancelledRef = try await create(auth, cancelled)
        try await auth.cancel(operationID: cancelledRef.authorizationID)
        let consumed = Fixture()
        let (consumedRef, _) = try await driveToPermit(auth, consumed)
        _ = try await auth.consumePermit(consumedRef, expectation: consumed.expectation())

        clock.advanceMonotonic(by: .seconds(121))
        await auth.sweep()
        await #expect(throws: WorkspaceOperatorAuthorizationError.unknownOperation) {
            try await auth.status(of: cancelledRef.authorizationID)
        }
        #expect(try await auth.status(of: consumedRef.authorizationID) == .consumed)
        await #expect(throws: WorkspaceOperatorAuthorizationError.consumed) {
            try await auth.consumePermit(consumedRef, expectation: consumed.expectation())
        }

        // Capacity pressure eventually evicts even retained consumed markers;
        // the reference still rejects, safely, as unknown.
        for _ in 0..<WorkspaceOperatorAuthorizationLimits.maxOperations {
            _ = try await create(auth, Fixture())
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.unknownOperation) {
            try await auth.status(of: consumedRef.authorizationID)
        }
    }

    // MARK: - Restart and generation

    @Test func serviceRestartInvalidatesEverything() async throws {
        let clockA = TestClock()
        let clockB = TestClock()
        let authA = authorizer(clock: clockA)
        let authB = authorizer(clock: clockB)
        let fx = Fixture()
        let refA = try await create(authA, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challengeA = try await authA.issueChallenge(
            operationID: refA.authorizationID, uiConnection: ui)
        _ = try await authA.completeChallenge(
            challengeA, uiConnection: ui, result: .authenticated)

        await #expect(throws: WorkspaceOperatorAuthorizationError.wrongEpoch) {
            try await authB.completeChallenge(
                challengeA, uiConnection: ui, result: .authenticated)
        }
        // A reference minted under A carries A's epoch: B rejects it outright.
        let foreign = WorkspaceOperationAuthorizationReference(
            authorizationID: refA.authorizationID, epoch: await authA.epoch)
        await #expect(throws: WorkspaceOperatorAuthorizationError.wrongEpoch) {
            try await authB.consumePermit(foreign, expectation: fx.expectation())
        }
        await #expect(throws: WorkspaceOperatorAuthorizationError.unknownOperation) {
            try await authB.status(of: refA.authorizationID)
        }
    }

    @Test func newGenerationCannotConsumeOldPermit() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        // Host "reconnects" as a new generation: same workspace, new incarnation.
        let generation2 = WorkspaceHostGeneration()
        let reconnected = WorkspaceOperationRedemptionExpectation(
            workspace: fx.workspace, host: fx.host, generation: generation2,
            registration: WorkspaceHostRegistrationBinding(
                host: fx.host, generation: generation2, connectionID: UUID()),
            preparedLaunch: fx.preparedLaunch, intentDigest: fx.intentDigest, kind: fx.kind,
            definition: fx.definition)
        await #expect(throws: WorkspaceOperatorAuthorizationError.bindingMismatch) {
            try await auth.consumePermit(ref, expectation: reconnected)
        }
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())
    }

    // MARK: - Status and audit

    @Test func statusWalksEveryState() async throws {
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let ui = AuthenticatedOperatorUIConnectionID()

        let pending = try await create(auth, Fixture())
        #expect(try await auth.status(of: pending.authorizationID) == .pending)

        let awaitingFx = Fixture()
        let awaiting = try await create(auth, awaitingFx)
        _ = try await auth.issueChallenge(
            operationID: awaiting.authorizationID, uiConnection: ui)
        #expect(try await auth.status(of: awaiting.authorizationID) == .awaitingAuthentication)

        let authorizedFx = Fixture()
        let (authorized, _) = try await driveToPermit(auth, authorizedFx)
        #expect(try await auth.status(of: authorized.authorizationID) == .authorized)

        let consumedFx = Fixture()
        let (consumed, _) = try await driveToPermit(auth, consumedFx)
        _ = try await auth.consumePermit(consumed, expectation: consumedFx.expectation())
        #expect(try await auth.status(of: consumed.authorizationID) == .consumed)

        let cancelled = try await create(auth, Fixture())
        try await auth.cancel(operationID: cancelled.authorizationID)
        #expect(try await auth.status(of: cancelled.authorizationID) == .cancelled)

        let failedFx = Fixture()
        let failedRef = try await create(auth, failedFx)
        let failedChallenge = try await auth.issueChallenge(
            operationID: failedRef.authorizationID, uiConnection: ui)
        _ = try? await auth.completeChallenge(
            failedChallenge, uiConnection: ui, result: .unavailable)
        #expect(try await auth.status(of: failedRef.authorizationID) == .failed)

        let invalidatedFx = Fixture()
        let (invalidated, _) = try await driveToPermit(auth, invalidatedFx)
        await auth.hostDisconnected(connectionID: invalidatedFx.registration.connectionID)
        #expect(try await auth.status(of: invalidated.authorizationID) == .invalidated)

        let expired = try await create(auth, Fixture())
        clock.advanceMonotonic(by: .seconds(121))
        #expect(try await auth.status(of: expired.authorizationID) == .expired)
    }

    @Test func auditTrailIsCompleteAndClean() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let ui = AuthenticatedOperatorUIConnectionID()
        let ref = try await create(auth, fx)
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        _ = try await auth.completeChallenge(challenge, uiConnection: ui, result: .authenticated)
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())
        _ = try? await auth.consumePermit(ref, expectation: fx.expectation())

        #expect(recorder.kinds == [
            .operationCreated, .challengeIssued, .authenticationCompleted,
            .permitIssued, .permitConsumed, .replayRejected,
        ])
        for event in recorder.all {
            #expect(event.operationID == ref.authorizationID)
            #expect(event.workspace == fx.workspace)
            #expect(event.host == fx.host)
            #expect(event.generation == fx.generation)
            #expect(event.preparedLaunch == fx.preparedLaunch)
            #expect(event.intentDigestHex == Fixture.matchingDigest)
            #expect(event.operationKind == fx.kind)
        }
        let issued = recorder.all.first { $0.kind == .permitIssued }
        #expect(issued?.actor == OperatorAuthorizationActor(
            mechanism: .deviceOwnerAuthentication, uiConnection: ui))
        #expect(recorder.all.first { $0.kind == .operationCreated }?.actor == nil)
    }

    // MARK: - No authority effects

    #if os(macOS)
    @Test func issuedPermitChangesNoLaunchAuthorization() async throws {
        // Even with a live issued permit in hand, every launch operation stays
        // denied for every component role: Step 3 wires to no allow path.
        // The identity-launch ops exist as reserved cases and require a
        // permit; the direct door answers requiresOperatorPermit and never
        // spawns (see HostRedemptionTests).
        #expect(WorkspaceControlOp(rawValue: "launchAgentRuntime") == .launchAgentRuntime)
        #expect(WorkspaceControlOp(rawValue: "launchCustomRuntime") == .launchCustomRuntime)
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let (ref, _) = try await driveToPermit(auth, fx)
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)

        let roles: [TrustedRVComponentRole?] = [nil, .cli, .service, .workspaceHost]
        let operations: [WorkspaceControlOp] = [
            .launchRuntime, .launchAgentRuntime, .launchCustomRuntime, .ensureTerminalRuntime,
        ]
        for role in roles {
            let peer = PlatformPeerEvidence(
                processID: 1234,
                effectiveUserID: 501,
                auditToken: nil,
                codeIdentity: PeerCodeIdentity(
                    identifier: "test",
                    teamIdentifier: nil,
                    cdHash: Data(),
                    executablePath: "/tmp/test",
                    isAdHoc: true,
                    hardenedRuntime: false,
                    injectionExceptions: []
                ),
                componentRole: role
            )
            for operation in operations {
                #expect(
                    WorkspaceOperationAuthorization.permits(operation, peer: peer) == false,
                    "role \(String(describing: role)) op \(operation)")
            }
        }
        _ = try await auth.consumePermit(ref, expectation: fx.expectation())
        for role in roles {
            let peer = PlatformPeerEvidence(
                processID: 1234,
                effectiveUserID: 501,
                auditToken: nil,
                codeIdentity: PeerCodeIdentity(
                    identifier: "test",
                    teamIdentifier: nil,
                    cdHash: Data(),
                    executablePath: "/tmp/test",
                    isAdHoc: true,
                    hardenedRuntime: false,
                    injectionExceptions: []
                ),
                componentRole: role
            )
            for operation in operations {
                #expect(WorkspaceOperationAuthorization.permits(operation, peer: peer) == false)
            }
        }
    }
    #endif

    @Test func redemptionEchoesExactBindings() async throws {
        // The redemption record is data for future integration: it names the
        // exact operation, host incarnation, and ceremony — and nothing else.
        // No API accepts it yet, so it cannot cause any effect.
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ui = AuthenticatedOperatorUIConnectionID()
        let (ref, challenge) = try await driveToPermit(auth, fx, uiConnection: ui)
        let redemption = try await auth.consumePermit(ref, expectation: fx.expectation())
        #expect(redemption.authorizationID == ref.authorizationID)
        #expect(redemption.epoch == ref.epoch)
        #expect(redemption.challengeID == challenge.id)
        #expect(redemption.uiConnection == ui)
        #expect(redemption.workspace == fx.workspace)
        #expect(redemption.preparedLaunch == fx.preparedLaunch)
        #expect(redemption.intentDigest == fx.intentDigest)
        #expect(redemption.consumedMono == clock.monotonicNow())
    }

    @Test func uiDisconnectVersusCompletionIsCoherent() async throws {
        // Whoever wins, no usable permit survives: completion-then-disconnect
        // burns it, disconnect-then-completion rejects the completion.
        for _ in 0..<25 {
            let clock = TestClock()
            let auth = authorizer(clock: clock)
            let fx = Fixture()
            let ref = try await create(auth, fx)
            let ui = AuthenticatedOperatorUIConnectionID()
            let challenge = try await auth.issueChallenge(
                operationID: ref.authorizationID, uiConnection: ui)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try? await auth.completeChallenge(
                        challenge, uiConnection: ui, result: .authenticated)
                }
                group.addTask {
                    await auth.uiDisconnected(ui)
                }
            }
            #expect(try await auth.status(of: ref.authorizationID) == .invalidated)
            await #expect(throws: WorkspaceOperatorAuthorizationError.self) {
                try await auth.consumePermit(ref, expectation: fx.expectation())
            }
        }
    }

    @Test func concurrentDoubleCompletionMintsOnePermit() async throws {
        let clock = TestClock()
        let recorder = AuditRecorder()
        let auth = authorizer(clock: clock, recorder: recorder)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        let ui = AuthenticatedOperatorUIConnectionID()
        let challenge = try await auth.issueChallenge(
            operationID: ref.authorizationID, uiConnection: ui)
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await auth.completeChallenge(
                            challenge, uiConnection: ui, result: .authenticated)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await won in group where won { count += 1 }
            return count
        }
        #expect(wins == 1)
        #expect(recorder.count(of: .permitIssued) == 1)
        #expect(try await auth.status(of: ref.authorizationID) == .authorized)
    }

    @Test func disconnectAfterExpiryReportsExpired() async throws {
        // Challenge dead but parent live: the record is retained, and the
        // disconnect must not relabel the timeout as an invalidation.
        let clock = TestClock()
        let auth = authorizer(clock: clock)
        let fx = Fixture()
        let ref = try await create(auth, fx)
        _ = try await auth.issueChallenge(
            operationID: ref.authorizationID,
            uiConnection: AuthenticatedOperatorUIConnectionID())
        clock.advanceMonotonic(by: .seconds(61))
        await auth.hostDisconnected(connectionID: fx.registration.connectionID)
        #expect(try await auth.status(of: ref.authorizationID) == .expired)
    }
}
