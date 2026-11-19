#if os(macOS)
import Foundation
import Testing
@testable import RVCLI
@testable import RVIsolation

// A host that never answers (the live case: the peer-trust manifest pins the
// workspace host to another build) must not hang start, must not read as
// healthy in status, and must be stoppable by close.

private let endpoint = WorkspaceEndpoint(
    host: WorkspaceHostID(rawValue: UUID()),
    workspace: UUID(),
    canonicalPath: "/p",
    socketPath: "/p.sock",
    socketDevice: 1,
    socketInode: 2,
    ownerToken: UUID(),
    uid: getuid()
)

private let pinned = "manifest pins rv-workspace-host cdhash a5331737d2161ce1dc7e2167de78783e084a458c at "
    + "/Library/Application Support/RV/phase2a-development/rv-workspace-host; installed rv-workspace-host is cdhash "
    + "a150a5ddb10b8d5ce1bb1a42c93a0f5db8877173 at /Users/u/.local/bin/rv-workspace-host"

// MARK: - start

@Test func startRefusalNamesTheTrustReasonAndTheStoppedHost() {
    let text = WorkspaceCommandRun.ensureFailureText(.control(.unauthorizedClient), hostTrustReason: pinned)
    #expect(text.hasPrefix("the workspace host was refused: \(pinned)"))
    #expect(text.contains("any host this start launched was stopped"))
    #expect(text.contains("rv doctor"))
    #expect(text.contains("rv workspace leftovers"))
}

@Test func startRefusalWithoutAKnownReasonStillSaysWhy() {
    let text = WorkspaceCommandRun.ensureFailureText(.control(.unauthorizedClient), hostTrustReason: nil)
    #expect(text.hasPrefix("the workspace host was refused: "))
    #expect(text.contains("peer-trust"))
    #expect(text.contains("rv doctor"))
}

@Test func startNoAnswerSaysSoAndNamesTheBound() {
    let text = WorkspaceCommandRun.ensureFailureText(.notAnswering, hostTrustReason: nil)
    #expect(text.hasPrefix("the workspace host did not answer"))
    #expect(text.contains("\(Int(WorkspaceHosts.readinessTimeout)) s"))
    #expect(text.contains("any host this start launched was stopped"))
    #expect(text.contains("rv doctor"))
}

@Test func startOtherFailuresKeepTheirText() {
    #expect(WorkspaceCommandRun.ensureFailureText(.homeDirectory, hostTrustReason: pinned)
        == WorkspaceCommandRun.text(WorkspaceHostFailure.homeDirectory))
    #expect(WorkspaceCommandRun.text(WorkspaceHostFailure.notAnswering) == "the workspace host did not answer")
}

@Test func hostTrustReasonPerTrustSource() {
    let host = "/Users/u/.local/bin/rv-workspace-host"
    let missing = WorkspaceCommandRun.hostTrustReason(source: .siblingPin, hostPath: host)
    #expect(missing?.contains("no peer-trust manifest is installed") == true)
    #expect(missing?.contains(DoctorInstallChecks.trustManifestPath) == true)
    let invalid = WorkspaceCommandRun.hostTrustReason(source: .invalid, hostPath: host)
    #expect(invalid?.contains("present but rejected") == true)
}

// MARK: - status

@Test func statusOfAnUnansweredEndpointExitsNonZero() {
    let report = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in nil }
    #expect(report.text == WorkspaceCommandRun.staleEndpointText)
    #expect(report.exitCode == WorkspaceCommandRun.statusUnreachableExitCode)
    #expect(WorkspaceCommandRun.statusUnreachableExitCode == 1)
}

@Test func statusOfAStaleEndpointFileExitsNonZero() {
    let report = WorkspaceCommandRun.statusReport(.staleEndpoint) { _ in
        Issue.record("a stale endpoint is never connected")
        return nil
    }
    #expect(report.text == WorkspaceCommandRun.staleEndpointText)
    #expect(report.exitCode == 1)
}

@Test func statusOfAnsweringOrAbsentWorkspaceExitsZero() {
    let description = WorkspaceDescription(
        host: endpoint.host, workspace: endpoint.workspace, project: "/p", phase: .active, attached: 0
    )
    let live = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .success(description) }
    #expect(live.exitCode == 0)
    #expect(live.text == WorkspaceCommandRun.lines(description))
    let absent = WorkspaceCommandRun.statusReport(.absent) { _ in nil }
    #expect(absent.exitCode == 0)
    #expect(absent.text == WorkspaceCommandRun.text(WorkspaceAttachment.absent))
}

// MARK: - close

@Test func closeReportsTheStoppedHostAndWhatWasKept() {
    let text = WorkspaceCommandRun.closeUnreachableText(.stopped(4242))
    #expect(text.contains("stopped the workspace host rv launched for this project (pid 4242)"))
    #expect(text.contains("volume and saved changes are preserved"))
    #expect(text.contains("rv workspace leftovers"))
    #expect(text.contains("rv doctor"))
}

@Test func closeWithoutAStoppableHostSaysNothingWasStopped() {
    #expect(WorkspaceCommandRun.closeUnreachableText(.noRecord) == WorkspaceCommandRun.hostNotReachablePreservedText)
    let alone = WorkspaceCommandRun.closeUnreachableText(.leftAlone("process 9 runs /usr/bin/vim, not rv's host"))
    #expect(alone.hasPrefix(WorkspaceCommandRun.hostNotReachablePreservedText))
    #expect(alone.contains("nothing was stopped: process 9 runs /usr/bin/vim"))
    let gone = WorkspaceCommandRun.closeUnreachableText(.notRunning)
    #expect(gone.contains("already exited"))
    #expect(gone.contains("rv workspace leftovers"))
    let stuck = WorkspaceCommandRun.closeUnreachableText(.stillRunning(7))
    #expect(stuck.contains("pid 7"))
    #expect(stuck.contains("still running"))
}

/// A busy host is slow, not broken: close must not kill it.
@Test func closeStopsOnlyForFailuresThatProveTheHostUnusable() {
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .unauthorizedClient))
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .disconnected))
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .staleEndpoint))
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .timedOut) == false)
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .queueOverloaded) == false)
}
#endif
