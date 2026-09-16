import Foundation
import Testing
import RVDomain
@testable import RVService

@Test(arguments: [
    (FileToolKind.read, "read file"),
    (FileToolKind.edit, "edit file"),
    (FileToolKind.write, "write file"),
])
func pendingList_emptyEffectsFile_usesLedgerNameFile(
    kind: FileToolKind,
    expected: String
) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = PendingApproval(
        id: ApprovalID(rawValue: "file-\(kind.rawValue)"),
        identity: ApprovalIdentity(
            session: SessionID(validating: "sess")!,
            agent: .claude
        ),
        action: .file(
            FileAction(
                fingerprint: ActionFingerprint(
                    rawValue: "file:claude:sess:/tmp/ws:\(kind.rawValue):/tmp/a.md"
                ),
                file: FileToolAction(kind: kind, path: FileToolPath(rawValue: "/tmp/a.md")),
                effects: ActionEffects(),
                resources: ActionResources(path: "/tmp/a.md"),
                scope: ActionScope(workingDirectory: wd("/tmp/ws"))
            )
        ),
        reason: .hostAsk,
        continuation: .hostNative,
        timeoutPolicy: .keepWaiting,
        createdAt: now,
        expiresAt: now.addingTimeInterval(3600),
        state: .awaitingHuman
    )
    let items = PendingListProjection.items(from: [record])
    #expect(items.map(\.actionKind) == [expected])
}

@Test func pendingList_emptyEffectsShell_staysShell() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let record = PendingApproval(
        id: ApprovalID(rawValue: "shell-empty"),
        identity: ApprovalIdentity(
            session: SessionID(validating: "sess")!,
            agent: .pi
        ),
        action: .shell(
            ShellAction(
                fingerprint: ActionFingerprint(rawValue: "pi:sess:/tmp/ws:git status"),
                effects: ActionEffects(),
                scope: ActionScope(workingDirectory: wd("/tmp/ws")),
                supportingCommand: ShellCommand(rawValue: "git status")
            )
        ),
        reason: .hostAsk,
        continuation: .hostNative,
        timeoutPolicy: .keepWaiting,
        createdAt: now,
        expiresAt: now.addingTimeInterval(3600),
        state: .awaitingHuman
    )
    let items = PendingListProjection.items(from: [record])
    #expect(items.map(\.actionKind) == ["shell"])
}
