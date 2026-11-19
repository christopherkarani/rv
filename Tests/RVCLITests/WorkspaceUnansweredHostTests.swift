#if os(macOS)
import Foundation
import RVDomain
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

/// At the overall timeout `ensure` stops its host unless it was still
/// mounting or recovering; each outcome has its own, accurate text.
@Test func startTimeoutSaysTheLaunchedHostWasStopped() {
    let text = WorkspaceCommandRun.ensureFailureText(.timedOut, hostTrustReason: nil)
    #expect(text.hasPrefix("workspace host did not become ready"))
    #expect(text.contains("any host this start launched was stopped"))
    #expect(text.contains("rv workspace leftovers"))
}

@Test func startStillStartingSaysTheHostKeepsRunning() {
    let text = WorkspaceCommandRun.ensureFailureText(.stillStarting, hostTrustReason: nil)
    #expect(text.hasPrefix("the workspace host this start launched is still mounting or recovering"))
    #expect(text.contains("keeps running in the background"))
    #expect(text.contains("was stopped") == false)
    #expect(text.contains("rv workspace status"))
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

@Test func statusOfAnUnreachableEndpointExitsNonZero() {
    let report = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.staleEndpoint) }
    #expect(report.text == WorkspaceCommandRun.staleEndpointText)
    #expect(report.exitCode == WorkspaceCommandRun.statusUnreachableExitCode)
    #expect(WorkspaceCommandRun.statusUnreachableExitCode == 1)
}

/// A refused host is not a stale file: status names peer trust.
@Test func statusOfARefusedHostSaysPeerTrust() {
    let report = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.unauthorizedClient) }
    #expect(report.text.hasPrefix("refused (peer trust): "))
    #expect(report.text.contains("rv doctor"))
    #expect(report.exitCode == 1)
}

/// Each connect failure that is not a stale file says what it is.
@Test func statusNamesIncompatibleDisconnectedAndBusyHosts() {
    let incompatible = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.incompatibleProtocol) }
    #expect(incompatible.text.hasPrefix("incompatible protocol: "))
    #expect(incompatible.exitCode == 1)
    let disconnected = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.disconnected) }
    #expect(disconnected.text.hasPrefix("disconnected: "))
    #expect(disconnected.exitCode == 1)
    let busy = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.queueOverloaded) }
    #expect(busy.text.hasPrefix("busy: "))
    #expect(busy.exitCode == 1)
}

/// A host that does not answer in time is not a stale file either.
@Test func statusOfASilentHostSaysNotAnswering() {
    let report = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .connectFailed(.timedOut) }
    #expect(report.text.hasPrefix("not answering: "))
    #expect(report.text.contains("rv workspace status"))
    #expect(report.exitCode == 1)
}

@Test func statusOfAStaleEndpointFileExitsNonZero() {
    let report = WorkspaceCommandRun.statusReport(.staleEndpoint) { _ in
        Issue.record("a stale endpoint is never connected")
        return .connectFailed(.disconnected)
    }
    #expect(report.text == WorkspaceCommandRun.staleEndpointText)
    #expect(report.exitCode == 1)
}

@Test func statusOfAnsweringOrAbsentWorkspaceExitsZero() {
    let description = WorkspaceDescription(
        host: endpoint.host, workspace: endpoint.workspace, project: "/p", phase: .active, attached: 0
    )
    let live = WorkspaceCommandRun.statusReport(.live(endpoint)) { _ in .described(.success(description)) }
    #expect(live.exitCode == 0)
    #expect(live.text == WorkspaceCommandRun.lines(description))
    let absent = WorkspaceCommandRun.statusReport(.absent) { _ in .connectFailed(.disconnected) }
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

/// Close stops only a host that is refused or whose endpoint is stale. A
/// busy, disconnected or older-protocol host may still own live runtimes.
@Test func closeStopsOnlyForFailuresThatProveTheHostUnusable() {
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .unauthorizedClient))
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .staleEndpoint))
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .disconnected) == false)
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .timedOut) == false)
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .queueOverloaded) == false)
}

/// An incompatible protocol is a live older host, possibly with active
/// PTYs: close must not signal it.
@Test func closeLeavesAnIncompatibleHostRunning() {
    #expect(WorkspaceCommandRun.closeMayStopHost(after: .incompatibleProtocol) == false)
}
#endif
