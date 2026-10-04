import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// Step 8B.1 TTY attestation: the ONLY generic-IPC path that plants
/// authority, and only for the pinned genuine CLI after its in-binary
/// ceremony (display → LocalAuthentication → attest). Same-user IPC
/// callers, other roles, malformed fields, replays, substitutions, and
/// restarts must all fail closed.
@Suite("TTY attestation authority")
struct TTYAttestationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func attestAsCliPlantsAndSpendsExactlyOnce() async throws {
        let runtime = try makeRuntime()
        let params = attestParams(command: "git reset --hard", code: "abcdef")
        let first = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(params)),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = first.result else {
            Issue.record("cli attest must plant, got \(first.result)")
            return
        }
        #expect(reply.planted)
        #expect(reply.epoch.isEmpty == false)

        let allowed = await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .allow = allowed.result.decision else {
            Issue.record("attested command must allow once, got \(allowed.result.decision)")
            return
        }
        let replay = await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = replay.result.decision else {
            Issue.record("replay after spend must deny, got \(replay.result.decision)")
            return
        }
    }

    @Test func attestAsNonCliFailsClosedWithoutPlant() async throws {
        let contexts: [(String, AuthenticatedRequestContext)] = [
            ("unauthenticated", .unauthenticated),
            ("nil-role peer", peerHookContext()),
            ("service", peerServiceContext()),
            ("operatorUI", peerOperatorUIContext()),
        ]
        for (name, context) in contexts {
            let runtime = try makeRuntime()
            let denied = await runtime.dispatch(
                IPCRequest(method: .attestTTYRedemption(
                    attestParams(command: "git reset --hard", code: "abcdef")
                )),
                context: context
            )
            #expect(
                denied.result == .error(.authorizationDenied),
                "attest as \(name) must fail closed"
            )
            let evaluated = await runtime.evaluate(
                EvaluationRequest(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    enabledPacks: dayOnePackIDs
                ),
                cwd: wd("/tmp/ws")
            )
            guard case .deny = evaluated.result.decision else {
                Issue.record("nothing may plant for \(name)")
                return
            }
        }
    }

    @Test func attestMalformedFieldsPlantNothing() async throws {
        let bad: [AttestTTYRedemptionParams] = [
            attestParams(command: "git reset --hard", code: "abcdef", fingerprint: "short"),
            attestParams(
                command: "git reset --hard", code: "abcdef",
                fingerprint: String(repeating: "Z", count: 64)
            ),
            attestParams(
                command: "git reset --hard", code: "abcdef",
                fingerprint: String(repeating: "a", count: 64).uppercased()
            ),
            attestParams(command: "git reset --hard", code: "abcdef", codeHash: "xyz"),
            attestParams(
                command: "git reset --hard", code: "abcdef",
                codeHash: String(repeating: "0", count: 63)
            ),
        ]
        for params in bad {
            let runtime = try makeRuntime()
            let denied = await runtime.dispatch(
                IPCRequest(method: .attestTTYRedemption(params)),
                context: peerCliContext()
            )
            #expect(denied.result == .error(.authorizationDenied))
            let evaluated = await runtime.evaluate(
                EvaluationRequest(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    enabledPacks: dayOnePackIDs
                ),
                cwd: wd("/tmp/ws")
            )
            guard case .deny = evaluated.result.decision else {
                Issue.record("malformed attest must plant nothing")
                return
            }
        }
    }

    @Test func doubleAttestPlantsOnce() async throws {
        let runtime = try makeRuntime()
        let params = attestParams(command: "git reset --hard", code: "abcdef")
        let first = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(params)),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = first.result, reply.planted else {
            Issue.record("first attest must plant, got \(first.result)")
            return
        }
        let second = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(params)),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let rereply) = second.result else {
            Issue.record("double attest must answer, got \(second.result)")
            return
        }
        #expect(rereply.planted == false)

        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let allowed = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .allow = allowed.result.decision else {
            Issue.record("one spend must allow, got \(allowed.result.decision)")
            return
        }
        let replay = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .deny = replay.result.decision else {
            Issue.record("double attest must not double spend")
            return
        }
    }

    @Test func attestBindsExactDigest() async throws {
        // Attest reset --hard; a different denied command still denies,
        // and the grant survives for the reviewed command.
        let runtime = try makeRuntime()
        let planted = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(
                attestParams(command: "git reset --hard", code: "abcdef")
            )),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = planted.result, reply.planted else {
            Issue.record("attest must plant, got \(planted.result)")
            return
        }
        let substituted = await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git push --force origin main"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = substituted.result.decision else {
            Issue.record("substituted command must deny, got \(substituted.result.decision)")
            return
        }
        let reviewed = await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .allow = reviewed.result.decision else {
            Issue.record("reviewed command must allow, got \(reviewed.result.decision)")
            return
        }
    }

    @Test func attestBindsExactCwd() async throws {
        let runtime = try makeRuntime()
        let planted = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(
                attestParams(command: "git reset --hard", code: "abcdef")
            )),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = planted.result, reply.planted else {
            Issue.record("attest must plant, got \(planted.result)")
            return
        }
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let crossed = await runtime.evaluate(request, cwd: wd("/tmp/other"))
        guard case .deny = crossed.result.decision else {
            Issue.record("cross-workspace spend must deny, got \(crossed.result.decision)")
            return
        }
        let home = await runtime.evaluate(request, cwd: wd("/tmp/ws"))
        guard case .allow = home.result.decision else {
            Issue.record("home-workspace spend must allow, got \(home.result.decision)")
            return
        }
    }

    @Test func restartInvalidatesAttestedGrants() async throws {
        // A restart is a fresh table (fresh epoch): the old attest's
        // grant is gone. Two runtimes model the before/after.
        let before = try makeRuntime()
        let planted = await before.dispatch(
            IPCRequest(method: .attestTTYRedemption(
                attestParams(command: "git reset --hard", code: "abcdef")
            )),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = planted.result, reply.planted else {
            Issue.record("attest must plant, got \(planted.result)")
            return
        }
        let after = try makeRuntime()
        let evaluated = await after.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = evaluated.result.decision else {
            Issue.record("restart must invalidate grants, got \(evaluated.result.decision)")
            return
        }
    }

    @Test func expiredAttestedGrantDenies() async throws {
        let box = AttestClockBox(now)
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            clock: { box.now }
        )
        let planted = await runtime.dispatch(
            IPCRequest(method: .attestTTYRedemption(
                attestParams(command: "git reset --hard", code: "abcdef")
            )),
            context: peerCliContext()
        )
        guard case .attestTTYRedemption(let reply) = planted.result, reply.planted else {
            Issue.record("attest must plant, got \(planted.result)")
            return
        }
        box.now = now.addingTimeInterval(EphemeralAllowOnceTable.maxTTL + 1)
        let evaluated = await runtime.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            ),
            cwd: wd("/tmp/ws")
        )
        guard case .deny = evaluated.result.decision else {
            Issue.record("expired grant must deny, got \(evaluated.result.decision)")
            return
        }
    }

    private func makeRuntime() throws -> ServiceRuntime {
        let homeURL = try isolatedHomeDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        return ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory(),
            clock: { self.now }
        )
    }

    private func attestParams(
        command: String,
        code: String,
        fingerprint: String? = nil,
        codeHash: String? = nil
    ) -> AttestTTYRedemptionParams {
        AttestTTYRedemptionParams(
            fingerprint: fingerprint ?? commandFingerprint(MatchingView(command)),
            cwd: wd("/tmp/ws"),
            codeHash: codeHash ?? sha256Hex(code),
            clientSemver: ProtocolVersion.serviceSemver
        )
    }
}

private final class AttestClockBox: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
