import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

/// The SDK `evaluate` reply carries, under observe, the verdict enforce
/// would have returned (`wouldBe`) next to the observed allow, so SDK
/// callers see what `rv test` / `rv explain` show.
@Suite("Service evaluate observe would-be")
struct ServiceRuntimeObserveWouldBeTests {
    /// Over the same-UID SDK socket, as an SDK client calls it.
    private static func evaluate(_ command: String, home: HomeDirectory) async throws -> EvaluateReply {
        let runtime = ServiceRuntime(home: home, allowOnceDirectory: try isolatedAllowOnceDirectory())
        let request = EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs)
        let response = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request))),
            sameUIDSocket: true
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected an evaluate reply, got \(response.result)")
            throw CancellationError()
        }
        return reply
    }

    @Test("observe: the reply is the observed allow and wouldBe is enforce's deny")
    func observeCarriesWouldBeDeny() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate("git reset --hard", home: home)
        #expect(reply.result.decision == .allow)
        guard case .deny(let deny)? = reply.wouldBe?.decision else {
            Issue.record("expected a would-be deny, got \(String(describing: reply.wouldBe))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test("observe, no judge bundle: an inline program's wouldBe is enforce's indeterminate")
    func observeCarriesFlooredIndeterminate() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate(#"python3 -c 'print(shred)'"#, home: home)
        #expect(reply.result.decision == .allow)
        #expect(reply.wouldBe?.decision == .indeterminate(.inlineProgramNeedsJudge))
    }

    @Test("observe: an allow enforce would also allow carries no wouldBe")
    func observeAllowHasNoWouldBe() async throws {
        let home = try guardHome(mode: "observe")
        defer { remove(home) }
        let reply = try await Self.evaluate("git status", home: home)
        #expect(reply.result.decision == .allow)
        #expect(reply.wouldBe == nil)
    }

    @Test("enforce: the reply is the deny and carries no wouldBe")
    func enforceHasNoWouldBe() async throws {
        let home = try guardHome(mode: nil)
        defer { remove(home) }
        let reply = try await Self.evaluate("git reset --hard", home: home)
        guard case .deny = reply.result.decision else {
            Issue.record("enforce must deny, got \(reply.result.decision)")
            return
        }
        #expect(reply.wouldBe == nil)
    }
}
