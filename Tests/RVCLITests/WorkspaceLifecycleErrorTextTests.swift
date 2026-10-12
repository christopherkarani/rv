import Foundation
import Testing
@testable import RVCLI
#if os(macOS)
import RVIsolation
#endif

// UX-05: workspace lifecycle refusals must state the workspace state, whether
// work is safe, and the next command to run — not a bare failure phrase.
#if os(macOS)
@Test func hostNotReachableTextStatesSafetyAndNextAction() {
    let text = WorkspaceCommandRun.hostNotReachableText
    #expect(text.contains("workspace host is not reachable"))
    #expect(text.contains("untouched"))
    #expect(text.contains("rv workspace status"))
    #expect(text.contains("rv doctor"))
}

@Test func staleEndpointTextStatesSafetyAndNextAction() {
    let fromInspect = WorkspaceCommandRun.text(WorkspaceAttachment.staleEndpoint)
    #expect(fromInspect.contains("stale endpoint"))
    #expect(fromInspect.contains("untouched"))
    #expect(fromInspect.contains("rv workspace status"))
    #expect(fromInspect.contains("rv doctor"))
    #expect(WorkspaceCommandRun.text(WorkspaceClientFailure.staleEndpoint) == fromInspect)
}

@Test func inspectTextNamesStateAndNextAction() {
    #expect(WorkspaceCommandRun.text(WorkspaceAttachment.absent).contains("rv workspace start"))
    #expect(WorkspaceCommandRun.text(WorkspaceAttachment.starting(nil)).contains("rv workspace status"))
    let orphaned = WorkspaceCommandRun.text(WorkspaceAttachment.orphaned(UUID()))
    #expect(orphaned.contains("saved tree is untouched"))
    #expect(orphaned.contains("rv workspace status"))
    let recovering = WorkspaceCommandRun.text(WorkspaceAttachment.recovering(UUID()))
    #expect(recovering.contains("untouched"))
    #expect(recovering.contains("rv workspace status"))
    let blocked = WorkspaceCommandRun.text(
        WorkspaceAttachment.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .missingVolume))
    )
    #expect(blocked.contains("missingVolume"))
    #expect(blocked.contains("saved tree is untouched"))
    #expect(blocked.contains("rv workspace abandon"))
}

@Test func abandonRefusalTextStatesSafetyAndNextAction() {
    let live = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.live)
    #expect(live.contains("nothing was changed"))
    #expect(live.contains("rv workspace close"))
    let notBlocked = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.notBlocked)
    #expect(notBlocked.contains("nothing was changed"))
    #expect(notBlocked.contains("rv workspace status"))
    let unavailable = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.configurationUnavailable)
    #expect(unavailable.contains("nothing was changed"))
    #expect(unavailable.contains("rv doctor"))
    let unsafe = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.unsafeReason(.corrupt))
    #expect(unsafe.contains("corrupt"))
    #expect(unsafe.contains("nothing was changed"))
    #expect(unsafe.contains("rv workspace status"))
    let unproven = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.unprovenOwner)
    #expect(unproven.contains("nothing was changed"))
    #expect(unproven.contains("rv workspace status"))
}

@Test func recoveryTextsNameAbandonAsTheWayOut() {
    let blocked = WorkspaceCommandRun.text(
        WorkspaceHostFailure.recoveryBlocked(WorkspaceRecoveryBlock(workspace: nil, reason: .tornLog))
    )
    #expect(blocked.contains("tornLog"))
    #expect(blocked.contains("rv workspace abandon"))
    let required = WorkspaceCommandRun.text(WorkspaceClientFailure.recoveryRequired)
    #expect(required.contains("rv workspace status"))
    #expect(required.contains("rv workspace abandon"))
}
#endif
