#if os(macOS)
import Foundation
import RVIsolation
import Testing
@testable import RVCLI

/// L3 on the Mac: the workspace host's real words for every start failure
/// have their own `BoxStartFailure` entry (never the fallback), so a new
/// host message shows up here instead of as raw text under `rv box`.
@Suite("rv box knows every host start failure")
struct BoxStartFailureMacTests {
    static let clientFailures: [WorkspaceClientFailure] = [
        .disconnected, .malformed, .requestTooLarge, .queueOverloaded, .timedOut, .incompatibleProtocol,
        .unauthorizedClient, .workspaceClosing, .workspaceClosed, .runtimeNotFound, .invalidRequest,
        .requiresOperatorPermit, .resourceProfileUnavailable, .resourceStagingFailed("~/.claude.json"),
        .recoveryRequired, .childTeardownFailed, .runtimeLimit, .staleEndpoint, .terminalUnavailable,
        .terminalBusy, .terminalLimit, .terminalPrefixCommitted,
    ]

    static let hostFailures: [WorkspaceHostFailure] = [
        .unsupported, .projectUnusable, .homeDirectory, .hostBinaryMissing, .spawnFailed, .endpointUnavailable,
        .timedOut, .timedOutAndStopped, .notAnswering, .stillStarting, .hostExited(1),
        .recoveryBlocked(WorkspaceRecoveryBlock(workspace: nil, reason: .missingVolume)),
        .control(.unauthorizedClient),
    ] + clientFailures.map { .control($0) }

    static func known(_ message: String) -> Bool {
        BoxStartFailure.entries.contains { message.hasPrefix($0.prefix) }
    }

    @Test func everyEnsureFailureHasAnEntry() {
        for failure in Self.hostFailures {
            let message = WorkspaceCommandRun.ensureFailureText(failure, hostTrustReason: nil)
            #expect(Self.known(message), "no entry for \(failure): \(message)")
            BoxStartFailureTests.expectOneLineOneFix(BoxStartFailure.refusal(message))
        }
    }

    @Test func everyLaunchFailureHasAnEntry() {
        for failure in Self.clientFailures {
            for message in [WorkspaceCommandRun.text(failure, resourceProfileID: nil),
                            WorkspaceCommandRun.text(failure, resourceProfileID: "claude-app")] {
                #expect(Self.known(message), "no entry for \(failure): \(message)")
            }
        }
        for failure: WorkspaceTerminalSessionFailure in [.noTerminal, .fellBehind, .outputClosed] {
            #expect(Self.known(WorkspaceCommandRun.text(failure, resourceProfileID: nil)))
        }
        #expect(Self.known(WorkspaceCommandRun.hostNotReachableText))
    }
}
#endif
