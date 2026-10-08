import ArgumentParser
import Foundation
import Testing
import RVIPC
@testable import RVCLI

/// `rv operator` argument validation. No service contact: `buildParams` is
/// pure client-side shape checking; rvd revalidates everything.
@Suite("Operator command validation")
struct OperatorCommandTests {
    private func propose(_ arguments: [String]) throws -> ProposeLaunchParams {
        try OperatorPropose.parse(arguments).buildParams()
    }

    @Test func namedRequiresDefinition() throws {
        let params = try propose(["--workspace", "/tmp/p", "--kind", "named",
            "--definition", "test-agent"])
        #expect(params.kind == "named")
        #expect(params.definitionID == "test-agent")
        #expect(params.executable == nil)
    }

    @Test func namedRejectsCustomFlags() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "named",
                "--definition", "d", "--executable", "/bin/x"])
        }
    }

    @Test func namedRequiresDefinitionFlag() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "named"])
        }
    }

    @Test func customRequiresExecutableAndDigest() throws {
        let params = try propose(["--workspace", "/tmp/p", "--kind", "custom",
            "--executable", "/bin/echo", "--digest", String(repeating: "a", count: 64)])
        #expect(params.kind == "custom")
        #expect(params.executable == "/bin/echo")
        #expect(params.definitionID == nil)
    }

    @Test func customRejectsDefinition() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "custom",
                "--executable", "/bin/echo", "--digest", "aa", "--definition", "d"])
        }
    }

    @Test func customRequiresBothFlags() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "custom",
                "--executable", "/bin/echo"])
        }
    }

    @Test func bogusKindRejected() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "bogus",
                "--definition", "d"])
        }
    }

    @Test func malformedUUIDHintsRejected() {
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "named",
                "--definition", "d", "--hostID", "not-a-uuid"])
        }
        #expect(throws: ValidationError.self) {
            try propose(["--workspace", "/tmp/p", "--kind", "named",
                "--definition", "d", "--sessionID", "not-a-uuid"])
        }
    }

    @Test func uuidHintsAccepted() throws {
        let host = UUID()
        let session = UUID()
        let params = try propose(["--workspace", "/tmp/p", "--kind", "named",
            "--definition", "d", "--hostID", host.uuidString,
            "--sessionID", session.uuidString])
        #expect(params.hostID == host)
        #expect(params.workspaceSessionID == session)
    }

    @Test func trailingArgumentsRecorded() throws {
        let params = try propose(["--workspace", "/tmp/p", "--kind", "named",
            "--definition", "d", "--", "--flag", "value"])
        #expect(params.arguments == ["--flag", "value"])
    }
}
