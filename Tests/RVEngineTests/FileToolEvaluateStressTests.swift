import Testing
import RVDomain
@testable import RVEngine

/// Malformed / foreign paths at `evaluateFileTool`. Grep / MCP never become
/// `FileToolAction` (decode foreign). Empty and secret paths deny.
///
/// Run: `tools/gate.sh --quiet RVEngineTests --filter FileToolEvaluateStress`
@Suite("File-tool evaluate stress")
struct FileToolEvaluateStressTests {
    @Test func emptyAndWhitespacePaths_denyCoreSecrets() {
        for raw in ["", "   ", "\n", "\t"] {
            let result = evaluateFileTool(
                FileToolAction(kind: .read, path: FileToolPath(rawValue: raw))
            )
            guard case .deny(let deny, _) = result.outcome else {
                Issue.record("empty path must deny, got \(result.decision) for \(raw.debugDescription)")
                continue
            }
            #expect(deny.ruleID.pack == .coreSecrets)
            #expect(UnlockableDeny.isPinned(result))
        }
    }

    @Test func secretBasenames_stillDeny() {
        let paths = [
            "/tmp/rv-oracle/.env",
            "/tmp/rv-oracle/.ssh/id_ed25519",
            "~/.claude/.credentials.json",
        ]
        for path in paths {
            let result = evaluateFileTool(
                FileToolAction(kind: .read, path: FileToolPath(rawValue: path))
            )
            guard case .deny = result.decision else {
                Issue.record("secret path must deny: \(path)")
                continue
            }
            #expect(UnlockableDeny.isPinned(result))
        }
    }

    @Test func ordinaryProjectFile_allows() {
        let result = evaluateFileTool(
            FileToolAction(
                kind: .write,
                path: FileToolPath(rawValue: "/tmp/rv-oracle/src/main.swift")
            )
        )
        #expect(result.decision == .allow)
    }

    @Test func foreignSchemeLooksLikePath_doesNotBecomePackEvaluate() {
        let result = evaluateFileTool(
            FileToolAction(kind: .read, path: FileToolPath(rawValue: "mcp://server/tool"))
        )
        #expect(result.decision == .allow)
    }

    @Test func kindsDoNotChangeCatalogDecision() {
        let path = FileToolPath(rawValue: "/tmp/rv-oracle/.env")
        let kinds: [FileToolKind] = [.read, .edit, .write]
        let decisions = kinds.map { kind in
            evaluateFileTool(FileToolAction(kind: kind, path: path)).decision
        }
        #expect(Set(decisions.map(String.init(describing:))).count == 1)
        guard case .deny = decisions[0] else {
            Issue.record("env must deny on every file-tool kind")
            return
        }
    }
}
