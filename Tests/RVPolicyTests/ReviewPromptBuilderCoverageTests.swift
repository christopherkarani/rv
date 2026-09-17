import Testing
import RVDomain
@testable import RVPolicy

struct ReviewPromptBuilderCoverageTests {
    @Test func shellPayload_includesOptionalResourceAndScopeFields() {
        let request = ReviewRequest(
            action: .shell(
                ShellAction(
                    fingerprint: ActionFingerprint(rawValue: "shell:fs.delete:/tmp/a"),
                    effects: ActionEffects(kinds: [.filesystemDelete]),
                    resources: ActionResources(
                        path: "/tmp/a",
                        filesystemScope: .insideRepository,
                        resourceKind: .sourceCode
                    ),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
                )
            ),
            context: ReviewContext(
                repository: RepositoryReviewContext(),
                environment: EnvironmentReviewContext(isCI: true)
            )
        )
        let text = ReviewPromptBuilder.payload(for: request).text
        #expect(text.contains("resources.path: /tmp/a"))
        #expect(text.contains("resources.filesystemScope: insideRepository"))
        #expect(text.contains("resources.resourceKind: sourceCode"))
        #expect(text.contains("effects: filesystemDelete"))
        #expect(text.contains("scope.workingDirectory: /tmp/ws"))
        #expect(text.contains("environment.isCI: true"))
        #expect(text.contains("repository.isSharedBranch: false"))
        #expect(text.contains("environment.labels:") == false)
        #expect(text.contains("supportingCommand (evidence only):") == false)
    }
}

struct GrantPresenceTests {
    @Test func cases_areDistinct() {
        #expect(GrantPresence.none != .pending)
        #expect(GrantPresence.none == .none)
        #expect(GrantPresence.pending == .pending)
    }
}
