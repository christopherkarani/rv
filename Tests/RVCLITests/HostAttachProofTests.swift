import Foundation
import Testing

/// Locks the process proof that CI plays marketed hosts after `rv setup`.
/// The oracle is `Scripts/host-attach-proof.sh`; this suite does not run it
/// (Darwin hook-grade and Linux PR already do).
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

        let pr = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/pr.yml"),
            encoding: .utf8
        )
        #expect(pr.contains("Scripts/host-attach-proof.sh"))
        #expect(pr.contains("Isolated-HOME host attach"))

        let linuxJob = pr.range(of: "name: swift test")
        let darwinJob = pr.range(of: "name: macos hook grade")
        let attach = pr.range(of: "Scripts/host-attach-proof.sh")
        #expect(linuxJob != nil && darwinJob != nil && attach != nil)

        let prAttachCount = pr.components(separatedBy: "Scripts/host-attach-proof.sh").count - 1
        #expect(prAttachCount >= 2, "Linux PR and Darwin hook-grade must both run the attach proof")

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
