import Foundation
import Synchronization
import Testing
import RVDomain
import RVHistory
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService

/// rvd's owner-presence check for owner actions (packs, safety, allowlist,
/// policy, egress review, workspace abandon) and Linux allow-once.
@Suite("Owner presence")
struct OwnerPresenceTests {
    /// Accepts exactly one password; counts calls; can block until released.
    final class FakeChecker: OwnerPasswordChecking, @unchecked Sendable {
        let accepted: String?
        let calls = Mutex(0)
        let gate: DispatchSemaphore?
        init(accepted: String?, gate: DispatchSemaphore? = nil) {
            self.accepted = accepted
            self.gate = gate
        }
        func check(_ password: String) -> Bool? {
            calls.withLock { $0 += 1 }
            gate?.wait()
            guard let accepted else { return nil }
            return password == accepted
        }
    }

    static func socketContext() -> AuthenticatedRequestContext {
        let id = UUID()
        return .captured(peer: .socketPeer(processID: 4242, effectiveUserID: 501, connectionID: id), connectionID: id)
    }

    static func cliContext() -> AuthenticatedRequestContext {
        let code = PeerCodeIdentity(identifier: "dev.rv.cli", teamIdentifier: "TEAM", cdHash: Data([1]),
            executablePath: "/usr/local/bin/rv-cli", isAdHoc: false, hardenedRuntime: true, injectionExceptions: [])
        let id = UUID()
        return .captured(
            peer: AuthenticatedPeer(
                evidence: PlatformPeerEvidence(processID: 7, effectiveUserID: 501, auditToken: Data([7]),
                    codeIdentity: code, componentRole: .cli),
                connectionID: id),
            connectionID: id)
    }

    @Test func genuineCLIIsAcceptedWithoutAProof() async {
        let checker = FakeChecker(accepted: "secret")
        let presence = OwnerPresence(checker: checker)
        #expect(await presence.verify(nil, context: Self.cliContext()) == .approved)
        #expect(checker.calls.withLock { $0 } == 0)
    }

    @Test func socketPeerNeedsTheRightPassword() async {
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"))
        let context = Self.socketContext()
        #expect(await presence.verify(nil, context: context) == .denied(.init(outcome: .proofRequired)))
        #expect(await presence.verify(OwnerProof(password: ""), context: context) == .denied(.init(outcome: .proofRequired)))
        #expect(await presence.verify(OwnerProof(password: "guess"), context: context) == .denied(.init(outcome: .wrongPassword)))
        #expect(await presence.verify(OwnerProof(password: "secret"), context: context) == .approved)
    }

    @Test func unauthenticatedCallerIsNeverApproved() async {
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"))
        #expect(await presence.verify(OwnerProof(password: "secret"), context: .unauthenticated)
            == .denied(.init(outcome: .proofRequired)))
    }

    @Test func fiveWrongPasswordsLockChecksOut() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let checker = FakeChecker(accepted: "secret")
        let presence = OwnerPresence(checker: checker, clock: { now.withLock { $0 } })
        let context = Self.socketContext()
        for _ in 0..<(OwnerPresence.maxFailures - 1) {
            #expect(await presence.verify(OwnerProof(password: "x"), context: context)
                == .denied(.init(outcome: .wrongPassword)))
        }
        guard case .denied(let locked) = await presence.verify(OwnerProof(password: "x"), context: context) else {
            Issue.record("fifth failure must lock")
            return
        }
        #expect(locked.outcome == .lockedOut)
        // Even the right password is refused while locked, without asking the helper.
        let callsBefore = checker.calls.withLock { $0 }
        guard case .denied(let still) = await presence.verify(OwnerProof(password: "secret"), context: context) else {
            Issue.record("locked checks must refuse")
            return
        }
        #expect(still.outcome == .lockedOut)
        #expect(checker.calls.withLock { $0 } == callsBefore)
        now.withLock { $0 = $0.addingTimeInterval(OwnerPresence.lockout + 1) }
        #expect(await presence.verify(OwnerProof(password: "secret"), context: context) == .approved)
    }

    @Test func aSecondCheckWhileOneIsRunningIsRefused() async throws {
        let gate = DispatchSemaphore(value: 0)
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret", gate: gate))
        let context = Self.socketContext()
        let first = Task { await presence.verify(OwnerProof(password: "secret"), context: context) }
        // Let the first check reach the helper before the second arrives.
        try await Task.sleep(for: .milliseconds(200))
        let second = await presence.verify(OwnerProof(password: "secret"), context: context)
        gate.signal()
        #expect(second == .denied(.init(outcome: .busy)))
        #expect(await first.value == .approved)
    }

    @Test func missingHelperIsReportedUnavailable() async {
        let presence = OwnerPresence(checker: FakeChecker(accepted: nil))
        #expect(await presence.verify(OwnerProof(password: "x"), context: Self.socketContext())
            == .denied(.init(outcome: .unavailable)))
    }

    @Test func proofIsNeverPrinted() {
        let proof = OwnerProof(password: "hunter2")
        #expect(String(describing: proof).contains("hunter2") == false)
        #expect(String(reflecting: proof).contains("hunter2") == false)
    }

    // MARK: dispatch

    private func runtime(checker: FakeChecker) throws -> (ServiceRuntime, HomeDirectory, URL) {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(), idleExitSeconds: IdleWatchdog.defaultSeconds,
            log: nil, analytics: nil, clock: { Date() }, pendingApprovals: .automatic,
            ceremonies: WorkspaceOperatorCeremonyService(), ownerPresence: OwnerPresence(checker: checker))
        return (runtime, home, homeURL)
    }

    private func auditLines(_ home: HomeDirectory) throws -> [String] {
        let url = AuditLog.fileURL(configDirectory: RVPolicyPaths.configDirectory(home: home))
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func confirmOwnerActionOverTheSocketApprovesAndAudits() async throws {
        let (runtime, home, url) = try runtime(checker: FakeChecker(accepted: "secret"))
        defer { try? FileManager.default.removeItem(at: url) }
        let wrong = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: "enable packs cloud.aws", proof: OwnerProof(password: "nope"), clientSemver: "1.0.0"))),
            context: Self.socketContext(), sameUIDSocket: true)
        #expect(wrong.result == .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .wrongPassword)))
        let right = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: "enable packs cloud.aws", proof: OwnerProof(password: "secret"), clientSemver: "1.0.0"))),
            context: Self.socketContext(), sameUIDSocket: true)
        #expect(right.result == .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .approved)))
        let lines = try auditLines(home)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("\"owner.action\"") && $0.contains("enable packs cloud.aws") })
        #expect(lines.allSatisfy { $0.contains("secret") == false && $0.contains("nope") == false })
        #expect(AuditChain.verify(Data((lines.joined(separator: "\n") + "\n").utf8)).isIntact)
    }

    @Test func unauthenticatedConfirmIsRefusedByTheMatrix() async throws {
        let (runtime, _, url) = try runtime(checker: FakeChecker(accepted: "secret"))
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: "set safety to normal", proof: OwnerProof(password: "secret"), clientSemver: "1.0.0"))))
        #expect(reply.result == .error(.authorizationDenied))
    }

    private func attest(_ proof: OwnerProof?) -> IPCMethod {
        .attestTTYRedemption(AttestTTYRedemptionParams(
            fingerprint: GrantFingerprint(rawValue: String(repeating: "a", count: 64)),
            cwd: wd("/tmp/ws"),
            codeHash: CodeHash(rawValue: String(repeating: "b", count: 64)),
            clientSemver: ProtocolVersion.serviceSemver,
            ownerProof: proof))
    }

    @Test func linuxAllowOncePlantsOnlyWithTheOwnersPassword() async throws {
        let (runtime, _, url) = try runtime(checker: FakeChecker(accepted: "secret"))
        defer { try? FileManager.default.removeItem(at: url) }
        let context = Self.socketContext()
        let none = await runtime.dispatch(IPCRequest(method: attest(nil)), context: context, sameUIDSocket: true)
        #expect(none.result == .error(.authorizationDenied))
        let wrong = await runtime.dispatch(
            IPCRequest(method: attest(OwnerProof(password: "nope"))), context: context, sameUIDSocket: true)
        #expect(wrong.result == .error(.authorizationDenied))
        let right = await runtime.dispatch(
            IPCRequest(method: attest(OwnerProof(password: "secret"))), context: context, sameUIDSocket: true)
        guard case .attestTTYRedemption(let reply) = right.result else {
            Issue.record("the owner's password must let a Linux peer redeem, got \(right.result)")
            return
        }
        #expect(reply.planted)
    }

    @Test func realUnixChkpwdRejectsAWrongPassword() {
        // Runs against the system helper when present; a random password
        // never matches any account's.
        let checker = UnixChkpwdChecker()
        guard UnixChkpwdChecker.candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        #expect(checker.check("rv-test-\(UUID().uuidString)") == false)
        #expect(checker.check("") == false)
    }

    @Test func helperThatExitsWithoutReadingIsAWrongPasswordNotACrash() {
        // The password write must not raise SIGPIPE in rvd when the helper
        // exits before reading its stdin.
        guard let quitter = ["/bin/false", "/usr/bin/false"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        var checker = UnixChkpwdChecker()
        checker.helpers = [quitter]
        for _ in 0..<20 {
            #expect(checker.check(String(repeating: "x", count: 400)) == false)
        }
    }
}
