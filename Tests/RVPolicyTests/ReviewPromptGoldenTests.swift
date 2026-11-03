import Foundation
import Testing
import RVDomain
@testable import RVPolicy

/// Pins the exact bytes the LLM reviewer sees (REQ-007 / CON-001).
///
/// Compile-level guarantee (cannot be a runtime test): `ReviewSanitizer` returns
/// `RedactedAction`, a type distinct from `ProposedAction`. Hard policy
/// (`ActionPolicyEngine.evaluate(action:context:policy:)`) takes a
/// `ProposedAction`, and `ReviewRequest` carries only the `RedactedAction`, so
/// evaluating hard policy on redacted input does not compile:
///
///     #if false
///     let request = ReviewRequest(action: action, context: context)
///     _ = ActionPolicyEngine.evaluate(action: request.action, context: request.context)
///     // error: cannot convert value of type 'RedactedAction' to expected
///     // argument type 'ProposedAction'
///     _ = ActionPolicyEngine.evaluate(request)   // no such overload
///     #endif
///
/// Redaction can delete the very text a deny rule matches, so policy must run
/// on the real action only.
struct ReviewPromptGoldenTests {
    private let context = ReviewContext(
        repository: RepositoryReviewContext(name: "rv", currentBranch: "main"),
        environment: EnvironmentReviewContext(labels: ["development"], isCI: false)
    )

    @Test func forcePushShell_withCredential_promptBytes() {
        let action = ProposedAction.shell(
            ShellAction.effectOnly(
                EffectShell(
                    fingerprint: ActionFingerprint(
                        rawValue: "shell:git.push https://ghp_exampletoken@github.com/org/repo.git"
                    ),
                    effects: ActionEffects(kinds: [.remoteSharedBranchMutation]),
                    resources: .git(
                        remote: RemoteName("origin"),
                        ref: .branch(BranchName("main"))
                    ),
                    scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/rv")),
                    supportingCommand: ShellCommand(
                        rawValue: "FOO=ghp_exampletoken git push --force https://ghp_exampletoken@github.com/org/repo.git"
                    )
                )
            )
        )
        let text = ReviewPromptBuilder.payload(
            for: ReviewRequest(action: action, context: context)
        ).text
        #expect(text == """
            \(ReviewPromptBuilder.instructions)

            kind: shell
            fingerprint: shell:git.push [redacted]
            effects: remoteSharedBranchMutation
            resources.remoteName: origin
            resources.branchName: main
            scope.workingDirectory: /tmp/rv
            repository.name: rv
            repository.currentBranch: main
            repository.isSharedBranch: true
            environment.isCI: false
            environment.labels: development
            supportingCommand (evidence only): FOO=[redacted] git push --force [redacted]
            """)
    }

    @Test func fileAction_promptBytes() {
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:write:/tmp/ws/a.txt"),
                file: FileToolAction(kind: .write, path: FileToolPath(rawValue: "/tmp/ws/a.txt")),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
            )
        )
        let text = ReviewPromptBuilder.payload(
            for: ReviewRequest(action: action, context: context)
        ).text
        #expect(text == """
            \(ReviewPromptBuilder.instructions)

            kind: file
            fingerprint: file:write:/tmp/ws/a.txt
            path: /tmp/ws/a.txt
            kind: write
            scope.workingDirectory: /tmp/ws
            repository.name: rv
            repository.currentBranch: main
            repository.isSharedBranch: true
            environment.isCI: false
            environment.labels: development
            """)
    }

    @Test func secretRequest_promptBytes() {
        let action = ProposedAction.secretRequest(SecretRequestAction(
            secret: "AWS", method: "POST", host: "example.com", path: "/",
            targetSHA256: "t", bodySHA256: "b", bodyBytes: 2, headersSHA256: "h", operationHeaders: []))
        let text = ReviewPromptBuilder.payload(
            for: ReviewRequest(action: action, context: context)
        ).text
        #expect(text == """
            \(ReviewPromptBuilder.instructions)

            kind: secretRequest
            secret: AWS
            method: POST
            destination: example.com/
            bodyBytes: 2
            repository.name: rv
            repository.currentBranch: main
            repository.isSharedBranch: true
            environment.isCI: false
            environment.labels: development
            """)
    }

    @Test func reviewRequest_encodedBytes_withCredential() throws {
        let action = ProposedAction.file(
            FileAction(
                fingerprint: ActionFingerprint(rawValue: "file:write:/tmp/ghp_exampletoken"),
                file: FileToolAction(kind: .write, path: FileToolPath(rawValue: "/tmp/ghp_exampletoken")),
                scope: ActionScope(workingDirectory: WorkingDirectory(validating: "/tmp/ws"))
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ReviewRequest(action: action, context: context))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json == #"{"action":{"file":{"_0":{"effects":{"kinds":[]},"file":{"kind":"write","path":"[redacted]"},"fingerprint":"[redacted]","resources":{"filesystemScope":{"unknown":{}},"path":"[redacted]","resourceKind":"unknown"},"scope":{"workingDirectory":"\/tmp\/ws"}}}},"context":{"environment":{"isCI":false,"labels":["development"]},"metadata":{},"repository":{"currentBranch":"main","name":"rv"}}}"#)
    }
}
