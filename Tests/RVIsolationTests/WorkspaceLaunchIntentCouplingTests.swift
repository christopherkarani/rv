import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Agreement between the workspace launch path and `WorkspaceLaunchIntent`.
///
/// Bounds the intent mirrors (`TerminalStreamLimits`,
/// `WorkspaceControlLimits`) are pinned behaviorally from the owning side's
/// constants, so a drift on either side fails loudly. The authorization
/// regression proves this PR enables nothing: every launch operation stays
/// denied for every component role.
@Suite("Workspace launch intent coupling")
struct WorkspaceLaunchIntentCouplingTests {
    private func custom(
        arguments: [String] = [],
        io: WorkspaceLaunchIO = .discard,
        executable: String = "/bin/agent",
        workingDirectory: String = "/tmp/proj"
    ) -> Result<WorkspaceLaunchIntent, WorkspaceLaunchIntentError> {
        WorkspaceLaunchIntent.makeCustom(
            executable: executable,
            expectedContentDigestSHA256: String(repeating: "a", count: 64),
            workspaceSessionID: WorkspaceSessionID(),
            workingDirectory: workingDirectory,
            arguments: arguments,
            io: io
        )
    }

    @Test func terminalDimensionsAgreeWithStreamLimits() {
        let probes = [(0, 24), (1, 1), (24, 80), (512, 512), (513, 512), (512, 513),
            (1, 0), (0, 0), (-1, 24), (24, -1)]
        for (rows, columns) in probes {
            let stream = TerminalStreamLimits.accepts(rows: rows, columns: columns)
            let intent = custom(io: .pseudoTerminal(rows: rows, columns: columns)).isSuccess
            #expect(stream == intent, "dimensions \(rows)x\(columns)")
        }
    }

    @Test func argumentBoundsAgreeWithControlLimits() throws {
        let atCount = Array(repeating: "a", count: WorkspaceControlLimits.maxArguments)
        #expect(try custom(arguments: atCount).get().arguments.count == WorkspaceControlLimits.maxArguments)
        let overCount = Array(repeating: "a", count: WorkspaceControlLimits.maxArguments + 1)
        #expect(custom(arguments: overCount) == .failure(.tooManyArguments))

        let atBytes = String(repeating: "a", count: WorkspaceControlLimits.maxArgumentBytes)
        #expect(try custom(arguments: [atBytes]).get().arguments == [atBytes])
        let overBytes = String(repeating: "a", count: WorkspaceControlLimits.maxArgumentBytes + 1)
        #expect(custom(arguments: [overBytes]) == .failure(.invalidArgument))
    }

    @Test func executableBoundAgreesWithControlLimits() throws {
        let stem = "/bin/"
        let atBytes = stem + String(
            repeating: "a", count: WorkspaceControlLimits.maxExecutableBytes - stem.utf8.count
        )
        #expect(atBytes.utf8.count == WorkspaceControlLimits.maxExecutableBytes)
        #expect(try custom(executable: atBytes).get().auditSummary.executable == atBytes)
        #expect(
            custom(executable: atBytes + "a") == .failure(.invalidExecutable)
        )
    }

    @Test func discardIOAcceptsNoDimensionsOnBothSides() {
        // The wire parser refuses a discard carrying dimensions, and the
        // intent cannot express one: `.discard` carries nothing.
        #expect(
            workspaceLaunchIO(io: "discard", rows: 24, columns: 80)
                == .failure(.invalidRequest)
        )
        #expect(workspaceLaunchIO(io: nil, rows: nil, columns: nil) == .success(.discard))
        switch WorkspaceLaunchIO.discard {
        case .discard:
            break
        case .pseudoTerminal:
            Issue.record("discard must not carry dimensions")
        }
    }

    #if os(macOS)
    @Test func intentAloneCannotAuthorizeLaunchOperations() throws {
        // The semantic object exists and digests, yet no launch operation
        // becomes reachable: authorization still denies every launch op for
        // every component role, including fully trusted ones.
        let digest = try custom(arguments: ["hello"]).get().canonicalDigest
        #expect(digest.sha256Hex.utf8.count == 64)
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
                    "operation \(operation) with role \(String(describing: role))"
                )
            }
        }
    }
    #endif
}

private extension Result {
    var isSuccess: Bool {
        switch self {
        case .success:
            true
        case .failure:
            false
        }
    }
}
