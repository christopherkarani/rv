import Testing
import RVDomain
@testable import RVPolicy

struct ReviewPromptBuilderCoverageTests {
    @Test func shellPayload_includesOptionalResourceAndScopeFields() {
        let request = ReviewRequest(
            action: .shell(
                ShellAction.effectOnly(
                    EffectShell(
                        fingerprint: ActionFingerprint(rawValue: "shell:fs.delete:/tmp/a"),
                        effects: ActionEffects(kinds: [.filesystemDelete]),
                        resources: ActionResources(
                            path: "/tmp/a",
                            filesystemScope: .insideRepository,
                            resourceKind: .sourceCode
                        ),
                        scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
                    )
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

    @Test func secretRequestPayload_showsOperationSelectingHeaders() {
        func text(_ shown: [SecretRequestAction.Header]) -> String {
            ReviewPromptBuilder.payload(for: ReviewRequest(
                action: .secretRequest(SecretRequestAction(
                    secret: "AWS", method: "POST", host: "secretsmanager.us-east-1.amazonaws.com", path: "/",
                    targetSHA256: "t", bodySHA256: "b", bodyBytes: 2, headersSHA256: "h", operationHeaders: shown)),
                context: ReviewContext(
                    repository: RepositoryReviewContext(), environment: EnvironmentReviewContext(isCI: false))
            )).text
        }
        #expect(text([.init(name: "x-amz-target", value: "secretsmanager.GetSecretValue")])
            .contains("headers: x-amz-target: secretsmanager.GetSecretValue"))
        #expect(text([]).contains("headers:") == false)
    }
}

struct GrantPresenceTests {
    @Test func cases_areDistinct() {
        #expect(GrantPresence.none != .pending)
        #expect(GrantPresence.none == .none)
        #expect(GrantPresence.pending == .pending)
    }
}
