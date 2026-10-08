import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

struct EvaluateDoorTests {
    @Test func cliPeekAndDiagnosticApplyNeverHonorFileGrants() async throws {
        // Step 8B.1: the CLI holds no grant authority. A granted
        // projection row on disk changes nothing: peeks deny and the
        // diagnostic in-process apply denies too (spend lives in the
        // daemon's memory, reachable only via ceremony + attestation).
        let directory = try isolatedAllowOnceDirectory()
        let client = try isolatedClient(transport: nil, allowOnceDirectory: directory)
        let store = AllowOnceStore(baseDirectory: directory)
        let tty = TTYCapability(stdinIsTTY: true, stdoutIsTTY: true, ci: false)
        let code = try await store.mint(
            matchingView: "git reset --hard",
            cwd: wd("/tmp/ws"),
            ruleID: nil,
            tty: tty,
            now: Date()
        )
        _ = try await store.redeem(code: code.rawValue, tty: tty, now: Date())

        let firstPeek = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        guard case .deny = firstPeek.decision else {
            Issue.record("CLI peek must deny despite the file row")
            return
        }
        let secondPeek = try await cliEvaluate("git reset --hard", allowOnceDirectory: directory)
        guard case .deny = secondPeek.decision else {
            Issue.record("CLI peek must deny on repeat")
            return
        }

        let applied = await client.evaluate(
            command: ShellCommand(rawValue: "git reset --hard"),
            cwd: wd("/tmp/ws")
        )
        #expect(applied.path == .inProcess)
        let deny = try #require(denyPayload(from: applied.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func downFallbackAppliesInProcessAndStillDenies() async throws {
        let client = try isolatedClient(transport: nil)
        let reply = await client.evaluate(command: ShellCommand(rawValue: "git reset --hard"))
        let deny = try #require(denyPayload(from: reply.result.decision))
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
        #expect(reply.path == .inProcess)
    }
}
