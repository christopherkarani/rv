#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
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
        func check(_ password: String) async -> Bool? {
            calls.withLock { $0 += 1 }
            if let gate {
                // Blocks a thread of its own, as the real helper does, never
                // a cooperative-pool thread.
                await withCheckedContinuation { continuation in
                    Thread.detachNewThread {
                        gate.wait()
                        continuation.resume()
                    }
                }
            }
            guard let accepted else { return nil }
            return password == accepted
        }
    }

    /// Stands in for rvd's LocalAuthentication prompt: answers `approve`,
    /// records each reason, can block until released or cancelled.
    final class FakeAuthenticator: OwnerAuthenticating, @unchecked Sendable {
        let approve: Bool
        let available: Bool
        let hangs: Bool
        let reasons = Mutex<[String]>([])
        init(approve: Bool, available: Bool = true, hangs: Bool = false) {
            self.approve = approve
            self.available = available
            self.hangs = hangs
        }
        func isAvailable() -> Bool { available }
        func authenticate(reason: String) async -> Bool {
            reasons.withLock { $0.append(reason) }
            if hangs {
                // Returns early only when the prompt is cancelled.
                try? await Task.sleep(for: .seconds(60))
                return false
            }
            return approve
        }
        var promptCount: Int { reasons.withLock { $0.count } }
    }

    /// An XPC peer rvd authenticated but gave no role: a macOS one-click
    /// install has no peer-trust manifest, so this is the installed rv-cli.
    static func unroledXPCContext() -> AuthenticatedRequestContext {
        let code = PeerCodeIdentity(identifier: "rv-cli", teamIdentifier: nil, cdHash: Data([9]),
            executablePath: "/Users/me/.local/bin/rv-cli", isAdHoc: true, hardenedRuntime: false,
            injectionExceptions: [])
        let id = UUID()
        return .captured(
            peer: AuthenticatedPeer(
                evidence: PlatformPeerEvidence(processID: 9, effectiveUserID: 501, auditToken: Data([9]),
                    codeIdentity: code, componentRole: nil),
                connectionID: id),
            connectionID: id)
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

    // MARK: owner actions with rvd's own prompt (macOS)

    @Test func ownerActionOnAnUnroledInstallIsApprovedByRvdsPrompt() async {
        let checker = FakeChecker(accepted: "secret")
        let prompt = FakeAuthenticator(approve: true)
        let presence = OwnerPresence(checker: checker, authenticator: prompt)
        #expect(await presence.confirm("set safety to strict", proof: nil, context: Self.unroledXPCContext())
            == .approved)
        #expect(prompt.reasons.withLock { $0 } == ["set safety to strict"])
        #expect(checker.calls.withLock { $0 } == 0)
    }

    @Test func theCLIRoleNoLongerSkipsTheOwnersPrompt() async {
        let prompt = FakeAuthenticator(approve: false)
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        #expect(await presence.confirm("enable packs cloud.aws", proof: nil, context: Self.cliContext())
            == .denied(.init(outcome: .declined)))
        #expect(prompt.promptCount == 1)
    }

    @Test func aPasswordIsNoSubstituteForRvdsPrompt() async {
        let prompt = FakeAuthenticator(approve: false)
        let checker = FakeChecker(accepted: "secret")
        let presence = OwnerPresence(checker: checker, authenticator: prompt)
        #expect(await presence.confirm("set safety to normal", proof: OwnerProof(password: "secret"),
            context: Self.socketContext()) == .denied(.init(outcome: .declined)))
        #expect(checker.calls.withLock { $0 } == 0)
    }

    @Test func unauthenticatedCallerNeverRaisesAPrompt() async {
        let prompt = FakeAuthenticator(approve: true)
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        #expect(await presence.confirm("set safety to normal", proof: nil, context: .unauthenticated)
            == .denied(.init(outcome: .proofRequired)))
        #expect(prompt.promptCount == 0)
    }

    @Test func noPromptAvailableIsReportedUnavailable() async {
        let prompt = FakeAuthenticator(approve: true, available: false)
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        #expect(await presence.confirm("set safety to normal", proof: nil, context: Self.unroledXPCContext())
            == .denied(.init(outcome: .unavailable)))
        #expect(prompt.promptCount == 0)
    }

    @Test func fiveDeclinedPromptsLockOwnerActionsOut() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let prompt = FakeAuthenticator(approve: false)
        let presence = OwnerPresence(
            checker: FakeChecker(accepted: "secret"), authenticator: prompt, clock: { now.withLock { $0 } })
        let context = Self.unroledXPCContext()
        for _ in 0..<(OwnerPresence.maxFailures - 1) {
            #expect(await presence.confirm("x", proof: nil, context: context) == .denied(.init(outcome: .declined)))
        }
        guard case .denied(let locked) = await presence.confirm("x", proof: nil, context: context) else {
            Issue.record("fifth decline must lock")
            return
        }
        #expect(locked.outcome == .lockedOut)
        // While locked, no prompt is shown at all: an agent cannot keep one on screen.
        guard case .denied(let still) = await presence.confirm("x", proof: nil, context: context) else {
            Issue.record("locked checks must refuse")
            return
        }
        #expect(still.outcome == .lockedOut)
        #expect(prompt.promptCount == OwnerPresence.maxFailures)
    }

    /// A prompt LocalAuthentication could not show or that the system
    /// cancelled (rvd in a background session, biometry locked out) is not
    /// the owner saying no: it must never count toward the lockout.
    final class EnvironmentFailingAuthenticator: OwnerAuthenticating, @unchecked Sendable {
        let prompts = Mutex(0)
        func authenticate(reason: String) async -> Bool { false }
        func prompt(reason: String) async -> OwnerPromptOutcome {
            prompts.withLock { $0 += 1 }
            return .unavailable
        }
    }

    @Test func promptsThatCouldNotBeShownNeverLockTheOwnerOut() async {
        let prompt = EnvironmentFailingAuthenticator()
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        let context = Self.unroledXPCContext()
        for _ in 0..<(OwnerPresence.maxFailures * 2) {
            #expect(await presence.confirm("x", proof: nil, context: context) == .denied(.init(outcome: .unavailable)))
        }
        #expect(prompt.prompts.withLock { $0 } == OwnerPresence.maxFailures * 2)
    }

    #if canImport(LocalAuthentication)
    @Test("LocalAuthentication errors: the owner's no counts, the environment's does not", arguments: [
        (LAError.Code.userCancel, OwnerPromptOutcome.declined),
        (.userFallback, .declined),
        (.authenticationFailed, .declined),
        (.appCancel, .declined),
        (.systemCancel, .unavailable),
        (.notInteractive, .unavailable),
        (.passcodeNotSet, .unavailable),
        (.biometryLockout, .unavailable),
        (.biometryNotAvailable, .unavailable),
        (.biometryNotEnrolled, .unavailable),
        (.invalidContext, .unavailable),
    ])
    func laErrorMapping(code: LAError.Code, expected: OwnerPromptOutcome) {
        #expect(LocalOwnerAuthenticator.outcome(for: code) == expected)
    }
    #endif

    @Test func aSecondPromptWhileOneIsOpenIsRefused() async throws {
        let prompt = FakeAuthenticator(approve: false, hangs: true)
        let presence = OwnerPresence(
            checker: FakeChecker(accepted: "secret"), authenticator: prompt, promptTimeout: .seconds(5))
        let context = Self.unroledXPCContext()
        let first = Task { await presence.confirm("first", proof: nil, context: context) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await presence.confirm("second", proof: nil, context: context) == .denied(.init(outcome: .busy)))
        first.cancel()
        _ = await first.value
        #expect(prompt.reasons.withLock { $0 } == ["first"])
    }

    @Test func anUnansweredPromptTimesOutAndFreesTheSlot() async {
        let prompt = FakeAuthenticator(approve: false, hangs: true)
        let presence = OwnerPresence(
            checker: FakeChecker(accepted: "secret"), authenticator: prompt, promptTimeout: .milliseconds(200))
        let context = Self.unroledXPCContext()
        let started = ContinuousClock.now
        #expect(await presence.confirm("x", proof: nil, context: context) == .denied(.init(outcome: .declined)))
        // The fake answers only after 60 s, so returning in under 30 s means
        // the 200 ms timeout fired. The slack absorbs a pool starved by other
        // suites (seen at ~11 s on CI) without hiding a broken timeout.
        #expect(ContinuousClock.now - started < .seconds(30))
        // The slot is free again: the next request reaches the prompt.
        #expect(await presence.confirm("y", proof: nil, context: context) == .denied(.init(outcome: .declined)))
        #expect(prompt.promptCount == 2)
    }

    @Test func withoutAPromptProviderOwnerActionsUseThePassword() async {
        // Linux: no LocalAuthentication, so rvd checks the login password.
        let presence = OwnerPresence(checker: FakeChecker(accepted: "secret"), authenticator: nil)
        let context = Self.socketContext()
        #expect(await presence.confirm("x", proof: nil, context: context) == .denied(.init(outcome: .proofRequired)))
        #expect(await presence.confirm("x", proof: OwnerProof(password: "guess"), context: context)
            == .denied(.init(outcome: .wrongPassword)))
        #expect(await presence.confirm("x", proof: OwnerProof(password: "secret"), context: context) == .approved)
    }

    // MARK: dispatch

    private func runtime(
        checker: FakeChecker, authenticator: (any OwnerAuthenticating)? = nil
    ) throws -> (ServiceRuntime, HomeDirectory, URL) {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            snapshots: nil, catalog: nil, home: home, allowOnce: nil,
            allowOnceDirectory: try isolatedAllowOnceDirectory(), idleExitSeconds: IdleWatchdog.defaultSeconds,
            log: nil, analytics: nil, clock: { Date() }, pendingApprovals: .automatic,
            ceremonies: WorkspaceOperatorCeremonyService(),
            ownerPresence: OwnerPresence(checker: checker, authenticator: authenticator))
        return (runtime, home, homeURL)
    }

    @Test func confirmOwnerActionOverXPCPromptsInRvdAndAudits() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let (runtime, home, url) = try runtime(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        defer { try? FileManager.default.removeItem(at: url) }
        let reply = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: "set safety to\u{07} strict", proof: nil, clientSemver: "1.0.0"))),
            context: Self.unroledXPCContext())
        // Only a current rvd says how it checked the owner; a CLI refuses
        // an approval without this.
        #expect(reply.result == .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .approved, presence: .daemonPrompt)))
        // The prompt shows rvd's escaped copy of the summary: an invisible
        // character is shown, never dropped.
        #expect(prompt.reasons.withLock { $0 } == ["set safety to\\u0007 strict"])
        let lines = try auditLines(home)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("\"owner.action\"") == true)
        #expect(lines.first?.contains("set safety to") == true)
    }

    /// The prompt is the only text the macOS owner reads before the CLI
    /// applies the full action, so it is never shortened (a long path must
    /// not cut the destination or a data-loss warning) and format or
    /// separator characters cannot reorder or hide what it says.
    @Test func ownerSummaryIsEscapedAndNeverTruncated() async throws {
        let prompt = FakeAuthenticator(approve: true)
        let (runtime, _, url) = try runtime(checker: FakeChecker(accepted: "secret"), authenticator: prompt)
        defer { try? FileManager.default.removeItem(at: url) }
        let spoofed = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: "export policy to /tmp/\u{202E}txt.exe\u{2028}discarding nothing", proof: nil,
                clientSemver: "1.0.0"))),
            context: Self.unroledXPCContext())
        #expect(spoofed.result == .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .approved, presence: .daemonPrompt)))
        #expect(prompt.reasons.withLock { $0 } == ["export policy to /tmp/\\u202etxt.exe\\u2028discarding nothing"])

        let tail = ", discarding its unpublished changes"
        let long = "abandon workspace /" + String(repeating: "a", count: ConfirmOwnerActionParams.maxSummaryBytes) + tail
        let refused = await runtime.dispatch(
            IPCRequest(method: .confirmOwnerAction(ConfirmOwnerActionParams(
                summary: long, proof: nil, clientSemver: "1.0.0"))),
            context: Self.unroledXPCContext())
        #expect(refused.result == .error(.authorizationDenied))
        #expect(prompt.promptCount == 1, "an over-long summary raises no prompt")
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
        #expect(right.result == .confirmOwnerAction(ConfirmOwnerActionReply(outcome: .approved, presence: .password)))
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

    // Linux allow-once redeem: see AllowOnceOwnerPromptTests (it needs a
    // code rvd issued).

    @Test func realUnixChkpwdRejectsAWrongPassword() async {
        // Runs against the system helper when present; a random password
        // never matches any account's.
        let checker = UnixChkpwdChecker()
        guard UnixChkpwdChecker.candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }
        #expect(await checker.check("rv-test-\(UUID().uuidString)") == false)
        #expect(await checker.check("") == false)
    }

    @Test func helperThatExitsWithoutReadingIsAWrongPasswordNotACrash() async {
        // The password write must not raise SIGPIPE in rvd when the helper
        // exits before reading its stdin.
        guard let quitter = ["/bin/false", "/usr/bin/false"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        var checker = UnixChkpwdChecker()
        checker.helpers = [quitter]
        for _ in 0..<20 {
            #expect(await checker.check(String(repeating: "x", count: 400)) == false)
        }
    }

    /// Where one helper wait ran.
    struct WaitThread: Sendable {
        let name: String?
        let inTask: Bool
        let isMain: Bool
        let at: DispatchTime
    }

    @Test func hungPasswordHelpersNeitherStarveRvdNorOutliveACancel() async throws {
        // More hung checks than the cooperative pool has threads. Each waits
        // up to `UnixChkpwdChecker.timeout` for its helper; on the pool that
        // would park every thread and stall every other rvd task. Rather than
        // timing an unrelated task (which other suites' load can delay), each
        // wait reports the thread it blocks on: a dedicated thread, never one
        // running a Swift task.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-chkpwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pids")
        let hung = dir.appendingPathComponent("unix_chkpwd")
        try Data("#!/bin/sh\necho $$ >> '\(pidFile.path)'\nexec /bin/sleep 30\n".utf8).write(to: hung)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hung.path)
        let waits = Mutex<[WaitThread]>([])
        let checker = {
            var checker = UnixChkpwdChecker()
            checker.helpers = [hung.path]
            checker.onWaitThread = {
                let wait = WaitThread(
                    name: Thread.current.name, inTask: withUnsafeCurrentTask { $0 != nil },
                    isMain: Thread.isMainThread, at: .now())
                waits.withLock { $0.append(wait) }
            }
            return checker
        }()
        let checks = ProcessInfo.processInfo.activeProcessorCount * 3
        let running = Task {
            await withTaskGroup(of: Bool?.self) { group in
                for _ in 0..<checks {
                    group.addTask { await checker.check("rv-test-password") }
                }
                return await group.reduce(into: [Bool?]()) { $0.append($1) }
            }
        }
        // Once every helper is up and hung, cancel, then watch them die. This
        // runs on a thread of its own so a starved pool cannot delay it.
        let (launched, survivors): ([pid_t], [pid_t]) = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                func pids() -> [pid_t] {
                    let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
                    return text.split(separator: "\n").compactMap { pid_t($0) }
                }
                let upBy = DispatchTime.now() + .seconds(60)
                while pids().count < checks, DispatchTime.now() < upBy {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                let launched = pids()
                running.cancel()
                // A helper launches only after its wait reported in, so none
                // can reach the checker's own timeout before the earliest
                // report plus `timeout`. Dying before then means the cancel
                // killed it.
                let earliest = waits.withLock { $0.map(\.at).min() } ?? .now()
                let beforeTimeout = earliest + UnixChkpwdChecker.timeout - .seconds(1)
                func alive() -> [pid_t] {
                    launched.filter { kill($0, 0) == 0 || errno != ESRCH }
                }
                while alive().isEmpty == false, DispatchTime.now() < beforeTimeout {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                continuation.resume(returning: (launched, alive()))
            }
        }
        let results = await running.value
        #expect(launched.count == checks, "only \(launched.count) of \(checks) helpers started")
        #expect(survivors.isEmpty, "helpers \(survivors) outlived the cancel")
        // A cancelled check is "cannot check", never a strike.
        #expect(results.count == checks)
        #expect(results.allSatisfy { $0 == nil })
        let seen = waits.withLock { $0 }
        #expect(seen.count == checks)
        #expect(seen.allSatisfy { $0.name == UnixChkpwdChecker.waitThreadName && $0.inTask == false && $0.isMain == false },
            "helper waits ran on \(seen)")
    }
}
