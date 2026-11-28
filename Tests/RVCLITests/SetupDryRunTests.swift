import Foundation
import Testing
import RVDomain
@testable import RVCLI

@Suite("rv setup --dry-run")
struct SetupDryRunTests {
    private func snapshot(_ paths: OwnedPaths, claude: HostAdapterInstallation, cursor: HostAdapterInstallation) -> HostAdapterInstallationSnapshot {
        func missing(_ host: HookHost) -> HostAdapterInstallation { .missing(paths.hostAdapter(for: host)) }
        return HostAdapterInstallationSnapshot(
            grok: missing(.grok), pi: missing(.pi), openCode: missing(.opencode), claude: claude,
            openClaw: missing(.openclaw), hermes: missing(.hermes), codex: missing(.codex), cursor: cursor,
            antigravity: missing(.antigravity), muse: missing(.muse))
    }

    @Test func listsEachHostsActionAndTheServiceWithoutWriting() throws {
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(atPath: home.rawValue) }
        let paths = OwnedPaths(home: home)
        let claude = paths.hostAdapter(for: .claude)
        let cursor = paths.hostAdapter(for: .cursor)
        let text = SetupDryRun.text(
            snapshot: snapshot(paths, claude: .absentFile(claude), cursor: .occupied(cursor)),
            paths: paths, force: false, observe: false)
        #expect(text.hasPrefix("rv setup --dry-run: nothing was written."))
        #expect(text.contains("claude       write    ~/"))
        #expect(text.contains("holds another hook; --force"))
        #expect(text.contains("grok         skip     not installed"))
        #expect(text.contains("and start rvd"))
        #expect(text.contains("guard.mode") == false)
        #expect(text.contains(home.rawValue) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.rawValue).isEmpty)

        let forced = SetupDryRun.text(
            snapshot: snapshot(paths, claude: .wired(path: claude, existingData: Data()), cursor: .occupied(cursor)),
            paths: paths, force: true, observe: true)
        #expect(forced.contains("refresh"))
        #expect(forced.contains("(already wired)"))
        #expect(forced.contains("replace"))
        #expect(forced.contains("watching (guard.mode observe)"))
    }

    @Test func dryRunRefusesJSON() {
        #expect(throws: (any Error).self) { try Setup.parse(["--dry-run", "--json"]) }
        #expect((try? Setup.parse(["--dry-run", "--force", "--observe"])) != nil)
    }
}
