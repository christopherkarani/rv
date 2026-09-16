import Foundation
import Testing
import RVDomain
@testable import RVEngine

@Suite("ApplySemantics executing sinks")
struct ApplySemanticsSinkTests {
    private let home = FilesystemAnalysisWorld.probed(
        FilesystemAnalysisContext(
            workingDirectory: WorkingDirectory(validating: "/repo"),
            repositoryRoot: RepositoryRoot(validating: "/repo"),
            homeDirectory: HomePath(validating: "/isolated-home")
        )
    )

    @Test func echoPipeBashNorcReset_matchesDirectInnermost() throws {
        let direct = try runSemanticsDoor("git reset --hard")
        let wrapped = try runSemanticsDoor("echo 'git reset --hard' | bash --norc")
        guard case .deny = direct.decision else {
            Issue.record("direct reset --hard must deny")
            return
        }
        guard case .deny = wrapped.decision else {
            Issue.record("piped bash --norc reset must deny, got \(wrapped.decision)")
            return
        }
        #expect(wrapped.analysis.innermost == direct.analysis.innermost)
        #expect(wrapped.analysis.wrappers == [.bash])
    }

    @Test func echoPipeBashRm_isDeniedBySemantics() throws {
        let command = "echo 'rm -rf ~' | bash"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(
            command,
            filesystemProbe: { _ in home }
        )
        guard case .deny = composed.decision else {
            Issue.record("piped rm -rf ~ must deny, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.filesystemAction != nil)
    }

    @Test func catHeredocPipeBash_deniesInnerReset() throws {
        let command = """
            cat <<'EOF' | bash
            git reset --hard
            EOF
            """
        let composed = try runSemanticsDoor(command)
        guard case .deny = composed.decision else {
            Issue.record("cat heredoc | bash reset must deny, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func bashDevStdinHeredoc_deniesInnerReset() throws {
        let command = """
            bash /dev/stdin <<'EOF'
            git reset --hard
            EOF
            """
        let composed = try runSemanticsDoor(command)
        guard case .deny = composed.decision else {
            Issue.record("bash /dev/stdin heredoc reset must deny, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func bashInitFileProcessSub_deniesInnerReset() throws {
        let command = "bash --init-file <(echo 'git reset --hard')"
        let composed = try runSemanticsDoor(command)
        guard case .deny = composed.decision else {
            Issue.record("process-sub init-file reset must deny, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func echoQuotedReset_withoutPipe_staysAllow() throws {
        let command = "echo 'git reset --hard'"
        let composed = try runSemanticsDoor(command)
        #expect(composed.decision == .allow)
        #expect(composed.analysis.wrappers.isEmpty)
        #expect(composed.analysis.gitAction == nil)
    }

    @Test func gitStatus_staysAllow() throws {
        let command = "git status"
        let composed = try runSemanticsDoor(command)
        #expect(composed.decision == .allow)
    }

    @Test func catHeredocPipeGrep_doesNotUnwrapToReset() throws {
        let command = """
            cat <<'EOF' | grep -c reset
            git reset --hard
            EOF
            """
        let pack = try runSemanticsPack(command)
        let composed = try runSemanticsDoor(command)
        #expect(composed.decision == pack.decision)
        #expect(composed.analysis.wrappers.isEmpty)
        #expect(composed.analysis.gitAction == nil)
    }

    @Test func echoPipeBashThenTee_deniesInnerReset() throws {
        let command = "echo 'git reset --hard' | bash | tee"
        let composed = try runSemanticsDoor(command)
        guard case .deny = composed.decision else {
            Issue.record("piped bash then tee reset must deny, got \(composed.decision)")
            return
        }
        #expect(composed.analysis.wrappers == [.bash])
        #expect(composed.analysis.innermost == .git(.reset(mode: .hard, target: nil)))
    }

    @Test func bashUnknownFlagAsStdinConsumer_deniesUnwrapLimited() throws {
        let command = "echo 'git reset --hard' | bash --unknown-flag"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("unmodeled sink option must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
        #expect(composed.analysis.wrappers == [.bash])
    }

    @Test func bashInitFileProcessSubCat_deniesUnwrapLimited() throws {
        let command = "bash --init-file <(cat somefile)"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("non-echo process-sub must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
        #expect(composed.analysis.wrappers == [.bash])
    }

    @Test func catFilePipeBash_deniesUnwrapLimited() throws {
        let command = "cat somefile | bash"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("cat file | bash must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
        #expect(composed.analysis.wrappers == [.bash])
    }

    @Test func echoAnsiCPipeBash_deniesUnwrapLimited() throws {
        let command = "echo $'git reset --hard' | bash"
        let pack = try runSemanticsPack(command)
        #expect(pack.decision == .allow)
        let composed = try runSemanticsDoor(command)
        guard case .deny(let deny) = composed.decision else {
            Issue.record("ANSI-C echo | bash must fail-closed, got \(composed.decision)")
            return
        }
        #expect(deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID)
        #expect(composed.analysis.innermost == .unwrapLimited)
        #expect(composed.analysis.wrappers == [.bash])
    }

    @Test func lift_0_14_applySemanticsCanaries() throws {
        for row in try loadLiftRows() {
            try assertLiftRow(row, filesystemWorld: home)
        }
    }
}

private struct LiftRow: Decodable {
    var id: String
    var command: String
    var expected: String
}

private struct LiftFile: Decodable {
    var cases: [LiftRow]
}

private func loadLiftRows() throws -> [LiftRow] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/corpus/lift_0_14.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(LiftFile.self, from: data).cases
}

private func assertLiftRow(
    _ row: LiftRow,
    filesystemWorld: FilesystemAnalysisWorld
) throws {
    switch row.expected {
    case "deny":
        let composed = try runSemanticsDoor(
            row.command,
            filesystemProbe: { _ in filesystemWorld }
        )
        guard case .deny = composed.decision else {
            Issue.record("\(row.id): expected deny, got \(composed.decision)")
            return
        }
    case "allow":
        // Historic isolation used a synthetic pack allow. The door keeps the
        // pack floor; semantics must still not unwrap these rows to git.
        let pack = try runSemanticsPack(row.command)
        let composed = try runSemanticsDoor(
            row.command,
            filesystemProbe: { _ in filesystemWorld }
        )
        #expect(composed.decision == pack.decision, "\(row.id) got \(String(describing: composed.decision))")
        #expect(composed.analysis.gitAction == nil, "\(row.id) must not unwrap to git")
        if pack.decision == .allow {
            #expect(composed.decision == .allow, "\(row.id) got \(String(describing: composed.decision))")
        }
    default:
        Issue.record("\(row.id): unknown expected \(row.expected)")
    }
}
