import Testing
import RVDomain
@testable import RVPolicy

@Suite("ProposedAction.file review surfaces")
struct ProposedActionFileReviewTests {
    @Test func reviewPromptBuilder_fileAction_emitsKindFilePathAndKind() {
        let path = "/tmp/notes.md"
        let request = ReviewRequest(
            action: .file(
                FileAction(
                    fingerprint: ActionFingerprint(rawValue: "file:claude:s1:/tmp/ws:write:\(path)"),
                    file: FileToolAction(kind: .write, path: FileToolPath(rawValue: path)),
                    effects: ActionEffects(),
                    resources: ActionResources(path: path),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
                )
            ),
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "main")
            )
        )
        let payload = ReviewPromptBuilder.payload(for: request)
        #expect(payload.text.contains("kind: file"))
        #expect(payload.text.contains("path: \(path)"))
        #expect(payload.text.contains("kind: write"))
        #expect(payload.text.contains("kind: shell") == false)
        #expect(payload.text.contains("supportingCommand (evidence only):") == false)
    }

    @Test func shadowMissingContext_readsWorkingDirectoryFromFileScope() {
        let file = FileToolAction(kind: .read, path: FileToolPath(rawValue: "/tmp/a.md"))
        let withoutCwd = ReviewRequest(
            action: .file(
                FileAction(
                    fingerprint: ActionFingerprint(rawValue: "file:cursor:::read:/tmp/a.md"),
                    file: file,
                    effects: ActionEffects(),
                    resources: ActionResources(path: "/tmp/a.md"),
                    scope: ActionScope()
                )
            ),
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "main")
            )
        )
        #expect(ShadowMissingContext.reasons(in: withoutCwd) == [.workingDirectory])

        let withCwd = ReviewRequest(
            action: .file(
                FileAction(
                    fingerprint: ActionFingerprint(rawValue: "file:cursor::/tmp/ws:read:/tmp/a.md"),
                    file: file,
                    effects: ActionEffects(),
                    resources: ActionResources(path: "/tmp/a.md"),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
                )
            ),
            context: ReviewContext(
                repository: RepositoryReviewContext(name: "rv", currentBranch: "main")
            )
        )
        #expect(ShadowMissingContext.reasons(in: withCwd).contains(.workingDirectory) == false)
    }

    @Test func rulePinning_fileActionSecretPath_hardStopsWithoutFakeCommand() {
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:claude:::read:.env"),
                file: FileToolAction(kind: .read, path: FileToolPath(rawValue: ".env")),
                effects: ActionEffects(),
                resources: ActionResources(path: ".env")
            )
        )
        #expect(RulePinning.hardStop(in: action) == .secretPath)
        #expect(action.supportingCommand == nil)
    }
}
