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

    /// Every reason `hostTrustReason` can give, and none.
    static let trustReasons: [String?] = [
        nil,
        WorkspaceCommandRun.hostTrustReason(source: .siblingPin, hostPath: "/usr/local/bin/rv-workspace-host"),
        WorkspaceCommandRun.hostTrustReason(source: .invalid, hostPath: "/usr/local/bin/rv-workspace-host"),
        "the installed workspace host is not pinned to this build",
    ]

    static let recoveryReasons: [WorkspaceRecoveryBlock.Reason] = [
        .publicationConflict, .missingVolume, .ambiguousOwnership, .ambiguousSavedTree,
        .unprovenProcess, .unrelatedMount, .tornLog, .corrupt,
    ]

    @Test func everyEnsureFailureHasAnEntry() {
        let failures = Self.hostFailures
            + Self.recoveryReasons.map { .recoveryBlocked(WorkspaceRecoveryBlock(workspace: nil, reason: $0)) }
        for failure in failures {
            for reason in Self.trustReasons {
                let message = WorkspaceCommandRun.ensureFailureText(failure, hostTrustReason: reason)
                #expect(Self.known(message), "no entry for \(failure): \(message)")
                let refusal = BoxStartFailure.refusal(message, hostTrustReason: reason)
                BoxStartFailureTests.expectOneLineOneFix(refusal)
                if failure == .control(.unauthorizedClient) { #expect(refusal == BoxStartFailure.trustPin) }
            }
        }
        for reason in Self.recoveryReasons {
            #expect(Self.known(WorkspaceCommandRun.blockedRecoveryText(reason)))
        }
    }

    /// Unreachable with a failing trust check reads as the trust pin.
    @Test func unreachableWithATrustReasonIsTheTrustPin() {
        for reason in Self.trustReasons.compactMap({ $0 }) {
            #expect(BoxStartFailure.refusal(WorkspaceCommandRun.hostNotReachableText, hostTrustReason: reason)
                == BoxStartFailure.trustPin)
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
