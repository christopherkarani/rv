import Foundation
import Testing
@testable import RVCLI
#if os(macOS)
import RVIsolation
#endif

// UX-05: workspace lifecycle refusals must state the workspace state, whether
// work is safe, and the next command to run — and must not overclaim either.
// The two tests below use only the shared strings, so Linux CI runs them.
// Inspect and refusal copy needs the macOS workspace types.
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
    let text = WorkspaceCommandRun.staleEndpointText
    #expect(text.contains("stale endpoint"))
    #expect(text.contains("saved endpoint could not be used"))
    #expect(text.contains("did not change the volume or saved tree"))
    #expect(text.contains("rv workspace status"))
    #expect(text.contains("rv doctor"))
    #expect(text.contains("did not answer") == false)
}

@Test func workspaceStatusAndLeftoversFieldTheProjectPath() throws {
    let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
    let project = "/tmp/p\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
    let status = WorkspaceCommandRun.statusLines(
        workspace: "11111111-1111-1111-1111-111111111111",
        host: "22222222-2222-2222-2222-222222222222",
        phase: "active",
        project: project,
        attached: 1
    )
    let leftover = WorkspaceCommandRun.leftoverProjectLine(
        project: project,
        attachment: "orphaned 33333333-3333-3333-3333-333333333333",
        detail: "last runtimeStarted at 2026-01-01T00:00:00Z"
    )
    for text in [status, leftover] {
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("\\u001b[2J\\u001b[H"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u2029"))
        #expect(text.contains("\\u202e"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
    }
    #expect(status.contains("phase active"))
    #expect(status.contains("attached 1"))
    #expect(status.split(separator: "\n").contains { $0.hasPrefix("project ") })

    let source = try String(contentsOf: workspaceCommandSourceURL(), encoding: .utf8)
    let described = try #require(swiftFunctionBody(source, "func lines(_ description: WorkspaceDescription)"))
    #expect(described.contains("statusLines("))
    #expect(described.contains("project: description.project"))
    #expect(described.contains("project \\(description.project)") == false)
    let row = try #require(swiftFunctionBody(source, "func leftoverLine("))
    #expect(row.contains("leftoverProjectLine("))
    #expect(row.contains("project: leftover.project"))
}

#if os(macOS)
@Test func staleEndpointSurfacesShareOneText() {
    let fromInspect = WorkspaceCommandRun.text(WorkspaceAttachment.staleEndpoint)
    #expect(fromInspect == WorkspaceCommandRun.staleEndpointText)
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

private func workspaceCommandSourceURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/RVCLI/Commands/WorkspaceCommand.swift")
}

private func swiftFunctionBody(_ source: String, _ signature: String) -> String? {
    guard let start = source.range(of: signature) else { return nil }
    let rest = source[start.upperBound...]
    guard let open = rest.firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < rest.endIndex {
        let character = rest[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return String(rest[open...index]) }
        }
        index = rest.index(after: index)
    }
    return nil
}
