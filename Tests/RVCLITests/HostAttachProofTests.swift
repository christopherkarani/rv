import Foundation
import Testing

/// Locks the process proof that CI plays marketed hosts after `rv setup`.
/// The oracle is `Scripts/host-attach-proof.sh`; this suite does not run it
/// (Linux PR and Darwin hook grade in macos-full.yml already do).
struct HostAttachProofTests {
    @Test func hostAttachProof_scriptAndCIWireTheThreeHostAttach() throws {
        let root = repoRootURL()
        let script = root.appendingPathComponent("Scripts/host-attach-proof.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let body = try String(contentsOf: script, encoding: .utf8)
        #expect(body.contains("AC-ATTACH-SETUP"))
        #expect(body.contains("AC-ATTACH-GROK-DENY"))
        #expect(body.contains("AC-ATTACH-GROK-ALLOW"))
        #expect(body.contains("AC-ATTACH-CODEX-DENY"))
        #expect(body.contains("AC-ATTACH-CODEX-ALLOW"))
        #expect(body.contains("AC-ATTACH-OPENCLAW-DENY"))
        #expect(body.contains("AC-ATTACH-OPENCLAW-ALLOW"))
        #expect(body.contains("git reset --hard"))
        #expect(body.contains("\"requireApproval\" in o"))
        #expect(body.contains("RV_ASK_CONFIRM") == false)

        // Linux runs it on every PR (pr.yml); Darwin in hook grade, which
        // lives in macos-full.yml (nightly, `ci:full` label, by hand).
        let pr = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/pr.yml"),
            encoding: .utf8
        )
        #expect(pr.contains("name: swift test"))
        #expect(pr.contains("Scripts/host-attach-proof.sh"), "Linux PR must run the attach proof")
        #expect(pr.contains("Isolated-HOME host attach"))

        let full = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/macos-full.yml"),
            encoding: .utf8
        )
        #expect(full.contains("name: macos hook grade"))
        #expect(full.contains("Scripts/host-attach-proof.sh"), "Darwin hook grade must run the attach proof")
        #expect(full.contains("Isolated-HOME host attach"))

        let release = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(release.contains("Scripts/host-attach-proof.sh"))
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
