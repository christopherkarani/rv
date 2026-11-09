import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

private func pendingProposalID(home: HomeDirectory) async throws -> String {
    let store = EgressReviewRun.store(home: home)
    let rule = try #require(LiveNetworkRule(host: "api.example.com", port: 443))
    let directory = try #require(WorkingDirectory(validating: "/tmp/rv-egress-run"))
    let request = try #require(EgressProposal.request(
        id: PendingApprovalStore.makeID(), rule: rule,
        workspaceSession: WorkspaceSessionID(), workspaceDirectory: directory
    ))
    return try await store.create(request, now: Date()).id.rawValue
}

struct EgressCommandRunTests {
    @Test func approve_requiresTTY() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false, output: out) {
            var command = try EgressApprove.parse([id])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress approve: requires an interactive TTY (stdin and stdout)\n")
    }

    @Test func approve_robotRefused() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, output: out) {
            var command = try EgressApprove.parse(["--robot", id])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress approve: --json/--robot refused\n")
    }

    @Test func approve_authFailed() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .failed, output: out
        ) {
            var command = try EgressApprove.parse([id])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress approve: device-owner authentication required\n")
    }

    @Test func deny_requiresTTY() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: false, stdoutIsTTY: false, output: out) {
            var command = try EgressDeny.parse([id, "--reason", "tracker"])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress deny: requires an interactive TTY (stdin and stdout)\n")
    }

    @Test func deny_robotRefused() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, stdinIsTTY: true, stdoutIsTTY: true, output: out) {
            var command = try EgressDeny.parse(["--json", id, "--reason", "tracker"])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress deny: --json/--robot refused\n")
    }

    @Test func deny_authFailed() async throws {
        let home = try isolatedHome()
        let id = try await pendingProposalID(home: home)
        let out = CLIOutputCapture()
        try await withCLIProcess(
            home: home, stdinIsTTY: true, stdoutIsTTY: true, ownerAuthOutcome: .failed, output: out
        ) {
            var command = try EgressDeny.parse([id, "--reason", "tracker"])
            await #expect(throws: ExitCode(2)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress deny: device-owner authentication required\n")
    }

    @Test func approve_missingHomeStillExit1() async throws {
        let out = CLIOutputCapture()
        try await withCLIProcess(environment: [:], stdinIsTTY: true, stdoutIsTTY: true, output: out) {
            var command = try EgressApprove.parse(["abc"])
            await #expect(throws: ExitCode(1)) { try await command.run() }
        }
        #expect(out.stderr == "rv egress approve: HOME is not set\n")
    }
}
