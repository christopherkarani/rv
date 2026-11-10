import Foundation
import Testing
import RVPresentation
@testable import RVCLI

/// Incident regression: a root-owned trust manifest pinned a Developer ID
/// rvd, a local ad-hoc rvd was installed, and setup wired every host anyway,
/// so the fail-closed hook denied every tool call. Setup must refuse before
/// writing anything when the installed rvd would be rejected.
private let untrusted = DoctorServiceTrust(
    source: "manifest",
    satisfied: false,
    reason: "manifest requires Developer ID dev.rv.rvd (team 5V273URY46); installed rvd is ad-hoc signed"
)

private func untrustedEnv(home: URL, launchctl: RecordingLaunchctl) -> SetupEnvironment {
    var environment = env(home: home, launchctl: launchctl)
    environment.daemonTrust = { _ in untrusted }
    return environment
}

@Test(arguments: [false, true])
func setup_untrustedRvd_refusesBeforeWritingAnything(force: Bool) throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
        let userSettings = Data(#"{"theme":"dark"}"#.utf8)
        try userSettings.write(to: URL(fileURLWithPath: layout.claudeSettings))

        let outcome = SetupRun.setup(untrustedEnv(home: home, launchctl: launchctl), force: force)

        #expect(outcome.exitCode != 0)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr.contains("rv setup failed: hooks would reject the installed rvd"))
        #expect(outcome.stderr.contains(untrusted.reason!))
        #expect(outcome.stderr.contains("RV_RELEASE_SIGN=1 Scripts/release.sh"))
        #expect(outcome.stderr.contains("sudo rm '/Library/Application Support/RV/peer-trust.json'"))
        // Nothing wired: the host config is byte-identical and no service loaded.
        #expect(try Data(contentsOf: URL(fileURLWithPath: layout.claudeSettings)) == userSettings)
        #expect(FileManager.default.fileExists(atPath: layout.claudeDirectory + "/hooks/rv-guard.py") == false)
        #expect(FileManager.default.fileExists(atPath: layout.claudeSettings + ".bak") == false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(launchctl.bootstraps.isEmpty)
    }
}

@Test func setup_trustedRvd_wiresAsBefore() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
        var environment = env(home: home, launchctl: launchctl)
        var evaluated: [String] = []
        environment.daemonTrust = { path in
            evaluated.append(path)
            return DoctorServiceTrust(source: "sibling-pin", satisfied: true, reason: nil)
        }
        let outcome = SetupRun.setup(environment)
        #expect(outcome.exitCode == 0)
        #expect(evaluated == [environment.rvdPath])
        #expect(FileManager.default.fileExists(atPath: layout.claudeDirectory + "/hooks/rv-guard.py"))
    }
}

/// Missing rvd keeps its own failure (rvd not found, nothing wired), not
/// the untrusted-daemon one.
@Test func setup_missingRvd_doesNotConsultTrust() throws {
    try withTempHome { home, _, launchctl in
        var environment = env(home: home, launchctl: launchctl, rvdPath: home.appendingPathComponent("absent-rvd").path)
        environment.daemonTrust = { _ in untrusted }
        let outcome = SetupRun.setup(environment)
        #expect(outcome.exitCode == EX_UNAVAILABLE)
        #expect(outcome.stderr.contains("rvd not found"))
        #expect(outcome.stderr.contains("hooks would reject") == false)
    }
}
