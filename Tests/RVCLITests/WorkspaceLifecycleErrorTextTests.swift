import Foundation
import Testing
@testable import RVCLI
#if os(macOS)
import RVIsolation
#endif

// UX-05: workspace lifecycle refusals must state the workspace state, whether
// work is safe, and the next command to run — and must not overclaim either.
#if os(macOS)
@Test func hostNotReachablePreservationIsOnlyForAttachAndClose() {
    let preserved = WorkspaceCommandRun.hostNotReachablePreservedText
    #expect(preserved.contains("workspace host is not reachable"))
    #expect(preserved.contains("left untouched"))
    #expect(preserved.contains("volume and saved changes are preserved"))
    #expect(preserved.contains("rv workspace status"))
    #expect(preserved.contains("rv doctor"))

    let afterEnsure = WorkspaceCommandRun.hostNotReachableText
    #expect(afterEnsure.contains("workspace host is not reachable"))
    #expect(afterEnsure.contains("rv workspace status"))
    #expect(afterEnsure.contains("rv doctor"))
    #expect(afterEnsure.contains("untouched") == false)
    #expect(afterEnsure.contains("preserved") == false)
    #expect(afterEnsure != preserved)

    let session = WorkspaceCommandRun.workspaceSessionFailedText
    #expect(session.contains("workspace host is not reachable") == false)
    #expect(session.contains("untouched") == false)
    #expect(session.contains("preserved") == false)
    #expect(session.contains("rv workspace status"))
}

@Test func staleEndpointTextStatesSafetyAndNextAction() {
    let fromInspect = WorkspaceCommandRun.text(WorkspaceAttachment.staleEndpoint)
    #expect(fromInspect.contains("stale endpoint"))
    #expect(fromInspect.contains("saved endpoint could not be used"))
    #expect(fromInspect.contains("did not change the volume or saved tree"))
    #expect(fromInspect.contains("rv workspace status"))
    #expect(fromInspect.contains("rv doctor"))
    #expect(fromInspect.contains("did not answer") == false)
    #expect(WorkspaceCommandRun.text(WorkspaceClientFailure.staleEndpoint) == fromInspect)
}

@Test func inspectTextNamesStateAndNextAction() {
    #expect(WorkspaceCommandRun.text(WorkspaceAttachment.absent).contains("rv workspace start"))
    let starting = WorkspaceCommandRun.text(WorkspaceAttachment.starting(nil))
    #expect(starting.contains("not ready"))
    #expect(starting.contains("rv workspace status"))
    #expect(starting.contains("published") == false)
    let orphaned = WorkspaceCommandRun.text(WorkspaceAttachment.orphaned(UUID()))
    #expect(orphaned.contains("rv workspace status"))
    #expect(orphaned.contains("rv workspace start"))
    #expect(orphaned.contains("reclaim"))
    #expect(orphaned.contains("untouched") == false)
    #expect(orphaned.contains("preserved") == false)
    let recovering = WorkspaceCommandRun.text(WorkspaceAttachment.recovering(UUID()))
    #expect(recovering.contains("wait"))
    #expect(recovering.contains("rv workspace status"))
    #expect(recovering.contains("untouched") == false)
    #expect(recovering.contains("preserved") == false)
}

@Test func blockedRecoveryTextNamesAbandonOnlyForAbandonableReasons() {
    let missingAttachment = WorkspaceCommandRun.text(
        WorkspaceAttachment.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .missingVolume))
    )
    let missingHost = WorkspaceCommandRun.text(
        WorkspaceHostFailure.recoveryBlocked(WorkspaceRecoveryBlock(workspace: nil, reason: .missingVolume))
    )
    #expect(missingAttachment == missingHost)
    #expect(missingAttachment.contains("missingVolume"))
    #expect(missingAttachment.contains("already absent"))
    #expect(missingAttachment.contains("saved tree is untouched"))
    #expect(missingAttachment.contains("restore the saved tree"))
    #expect(missingAttachment.contains("rv workspace abandon"))
    #expect(missingAttachment.contains("still present") == false)

    let conflictAttachment = WorkspaceCommandRun.text(
        WorkspaceAttachment.blocked(WorkspaceRecoveryBlock(workspace: nil, reason: .publicationConflict))
    )
    let conflictHost = WorkspaceCommandRun.text(
        WorkspaceHostFailure.recoveryBlocked(
            WorkspaceRecoveryBlock(workspace: nil, reason: .publicationConflict)
        )
    )
    #expect(conflictAttachment == conflictHost)
    #expect(conflictAttachment.contains("publicationConflict"))
    #expect(conflictAttachment.contains("rv workspace abandon"))
    #expect(conflictAttachment.contains("already absent") == false)
    #expect(conflictAttachment.contains("still present") == false)

    let unsafe: [WorkspaceRecoveryBlock.Reason] = [
        .tornLog, .corrupt, .ambiguousOwnership, .ambiguousSavedTree, .unprovenProcess, .unrelatedMount,
    ]
    for reason in unsafe {
        let block = WorkspaceRecoveryBlock(workspace: nil, reason: reason)
        let fromInspect = WorkspaceCommandRun.text(WorkspaceAttachment.blocked(block))
        let fromHost = WorkspaceCommandRun.text(WorkspaceHostFailure.recoveryBlocked(block))
        #expect(fromInspect == fromHost)
        #expect(fromInspect.contains(reason.rawValue))
        #expect(fromInspect.contains("abandon will refuse"))
        #expect(fromInspect.contains("rv workspace status"))
        #expect(fromInspect.contains("rv doctor"))
        #expect(fromInspect.contains("rv workspace abandon") == false)
        #expect(fromInspect.contains("still present") == false)
        #expect(fromInspect.contains("untouched") == false)
    }
}

@Test func abandonRefusalTextStatesSafetyAndNextAction() {
    let live = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.live)
    #expect(live.contains("nothing was changed"))
    #expect(live.contains("rv workspace close"))
    #expect(live.contains("publicationConflict"))
    #expect(live.contains("missingVolume"))
    #expect(live.contains("becomes blocked") == false)
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
    #expect(unsafe.contains("rv doctor"))
    let unproven = WorkspaceCommandRun.text(WorkspaceAbandonRefusal.unprovenOwner)
    #expect(unproven.contains("nothing was changed"))
    #expect(unproven.contains("rv workspace status"))
    #expect(unproven.contains("rv doctor"))
}

@Test func recoveryRequiredMentionsAbandonOnlyForAbandonableBlocks() {
    let required = WorkspaceCommandRun.text(WorkspaceClientFailure.recoveryRequired)
    #expect(required.contains("rv workspace status"))
    #expect(required.contains("rv workspace abandon"))
    #expect(required.contains("publicationConflict"))
    #expect(required.contains("missingVolume"))
    #expect(required.contains("only when"))
}

@Test func abandonFailedTextDoesNotClaimTheWorkspaceWasLeftAsIs() {
    let reasons: [WorkspaceRecoveryBlock.Reason?] = [nil, .publicationConflict, .tornLog, .missingVolume]
    for reason in reasons {
        let text = WorkspaceCommandRun.abandonFailedText(reason)
        #expect(text.contains("left as-is") == false)
        #expect(text.contains("nothing was changed") == false)
        #expect(text.contains("stopped before it finished"))
        #expect(text.contains("mid-abandon"))
        #expect(text.contains("recoveryBegan"))
        #expect(text.contains("rv workspace status"))
        #expect(text.contains("rv workspace abandon"))
        #expect(text.contains("idempotent"))
        if let reason {
            #expect(text.contains("abandon stopped: \(reason.rawValue)"))
        } else {
            #expect(text.hasPrefix("abandon failed"))
        }
    }
}
#endif
