#if canImport(Darwin)
import Darwin
#endif
import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
import RVTheme
import Synchronization
import Testing
@testable import RVCLI
#if canImport(XPC)
import RVService
#endif
#if os(macOS)
import RVIsolation
#endif

// MARK: - Fixtures

private struct InstallHome {
    var root: URL
    var paths: OwnedPaths
    var environment: DoctorEnvironment
}

private func withInstallHome(
    launchd: LaunchdObservation? = LaunchdObservation(guiDomainExists: true, loadedInGui: true, loadedInUser: false),
    trustManifest: TrustManifestState = .absent,
    daemonTrust: DoctorServiceTrust? = nil,
    userID: uid_t = getuid(),
    _ body: (inout InstallHome) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-doctor-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path + "/.config")
        try? FileManager.default.removeItem(at: root)
    }
    let home = try #require(HomeDirectory(validating: root.path))
    var fixture = InstallHome(
        root: root,
        paths: OwnedPaths(home: home),
        environment: DoctorEnvironment(
            home: home,
            pathEntries: [],
            fileManager: .default,
            launchAgentLoaded: launchd.map { $0.loadedInGui || $0.loadedInUser } ?? false,
            install: DoctorInstallProbes(
                userID: userID, launchd: launchd, trustManifest: trustManifest, daemonTrust: daemonTrust
            )
        )
    )
    try body(&fixture)
}

/// Healthy install layout: rvd + pack bundle in ~/.local/bin, plist naming
/// that rvd, ~/.config owner-only.
private func stageHealthyInstall(_ fixture: InstallHome) throws {
    try makeExecutable(URL(fileURLWithPath: fixture.paths.localRvd))
    try FileManager.default.createDirectory(
        atPath: (fixture.paths.localRvd as NSString).deletingLastPathComponent + "/" + DoctorInstallChecks.packBundleName,
        withIntermediateDirectories: true
    )
    try writePlist(fixture, rvd: fixture.paths.localRvd)
    try FileManager.default.createDirectory(atPath: fixture.root.path + "/.config", withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fixture.root.path + "/.config"
    )
}

private func writePlist(_ fixture: InstallHome, rvd: String) throws {
    try FileManager.default.createDirectory(
        atPath: (fixture.paths.launchAgent as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try LaunchAgentTemplate.rendered(rvdPath: rvd)
        .write(toFile: fixture.paths.launchAgent, atomically: true, encoding: .utf8)
}

private let runningDiagnostics = ServiceDiagnosticResult.xpc(
    snapshot: DoctorSnapshotReply(
        serviceSemver: "1.0.0",
        state: .running,
        idleExitSeconds: 300,
        packsEnabled: dayOnePackIDs,
        checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
    ),
    localCorePacksReady: true
)

private func problems(_ fixture: InstallHome) -> [DoctorProblem] {
    DoctorInstallChecks.problems(
        paths: fixture.paths,
        fileManager: fixture.environment.fileManager,
        probes: fixture.environment.install!
    )
}

private func doctorPretty(_ fixture: InstallHome, _ diagnostics: ServiceDiagnosticResult = runningDiagnostics) -> DoctorOutcome {
    DoctorRun.run(environment: fixture.environment, diagnostics: diagnostics, appearance: .pretty(colorOffPalette))
}

// MARK: - Install problem checks

@Test func doctorInstall_healthyLayoutHasNoProblemsAndExitsZero() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        #expect(problems(fixture).isEmpty)
        let outcome = doctorPretty(fixture)
        #expect(outcome.exitCode == 0)
        #expect(outcome.stdout.contains("fix:") == false)
    }
}

@Test func doctorInstall_jobOnlyInUserDomainWhileAquaExists_failsWithSetupFix() throws {
    try withInstallHome(
        launchd: LaunchdObservation(guiDomainExists: true, loadedInGui: false, loadedInUser: true)
    ) { fixture in
        try stageHealthyInstall(fixture)
        let found = problems(fixture)
        let problem = try #require(found.first { $0.id == "launchd-domain" })
        #expect(problem.severity == .fail)
        #expect(problem.summary.contains("user/"))
        #expect(problem.fix.contains("\(fixture.paths.localRv) setup"))
        #expect(doctorPretty(fixture).exitCode == 1)
    }
}

@Test func doctorInstall_jobInUserDomainWithoutAqua_isFine() throws {
    try withInstallHome(
        launchd: LaunchdObservation(guiDomainExists: false, loadedInGui: false, loadedInUser: true)
    ) { fixture in
        try stageHealthyInstall(fixture)
        #expect(problems(fixture).isEmpty)
    }
}

@Test func doctorInstall_plistRunsBuildTreeRvd_failsWithInstalledSetupFix() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        try writePlist(fixture, rvd: "/src/rv/.build/debug/rvd")
        let problem = try #require(problems(fixture).first { $0.id == "launch-agent-rvd" })
        #expect(problem.severity == .fail)
        #expect(problem.summary.contains("/src/rv/.build/debug/rvd"))
        #expect(problem.summary.contains(fixture.paths.localRvd))
        #expect(problem.fix == "run \(fixture.paths.localRv) setup")
    }
}

@Test func doctorInstall_invalidTrustManifest_namesFileAndNeedsSudo() throws {
    try withInstallHome(trustManifest: .invalid) { fixture in
        try stageHealthyInstall(fixture)
        let problem = try #require(problems(fixture).first { $0.id == "trust-manifest" })
        #expect(problem.severity == .fail)
        #expect(problem.summary.contains("/Library/Application Support/RV/peer-trust.json"))
        #expect(problem.summary.contains("rejected"))
        #expect(problem.fix.contains("sudo"))
    }
}

/// Ubuntu's pam_umask (002) leaves `~/.config` mode 775. rvd's socket is
/// under `~/.config` only on macOS; on Linux it is under the runtime
/// directory, so a 775 `~/.config` must not fail doctor there.
@Test func doctorInstall_umask002Config_failsOnlyWhereTheSocketLivesUnderIt() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let config = fixture.root.path + "/.config"
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: config)
        #if os(Linux)
        let runtime = try makeRuntimeDirectory(fixture, mode: 0o700)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: runtime)
        #expect(problems(fixture).isEmpty)
        #expect(doctorPretty(fixture).exitCode == 0)
        #else
        let problem = try #require(problems(fixture).first { $0.id == "config-dir" })
        #expect(problem.summary.contains("mode 775"))
        #expect(problem.fix == "chmod go-w '\(config)'")
        #endif
    }
}

#if !os(Linux)
/// macOS: the socket is under `~/.config`, so rvd applies its base-directory
/// rule there. Linux applies it to the runtime directory (below).
@Test func doctorInstall_groupWritableConfig_givesExactChmod() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let config = fixture.root.path + "/.config"
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: config)
        let problem = try #require(problems(fixture).first { $0.id == "config-dir" })
        #expect(problem.severity == .fail)
        #expect(problem.fix == "chmod go-w '\(config)'")
    }
}

@Test func doctorInstall_foreignOwnedConfig_givesExactChown() throws {
    try withInstallHome(userID: getuid() + 1) { fixture in
        try stageHealthyInstall(fixture)
        let config = fixture.root.path + "/.config"
        let problem = try #require(problems(fixture).first { $0.id == "config-dir" })
        #expect(problem.fix == "sudo chown \(getuid() + 1) '\(config)'")
    }
}

@Test func doctorInstall_configIsAFile_saysMoveItAside() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let config = fixture.root.path + "/.config"
        try FileManager.default.removeItem(atPath: config)
        try Data("x".utf8).write(to: URL(fileURLWithPath: config))
        let problem = try #require(problems(fixture).first { $0.id == "config-dir" })
        #expect(problem.summary.contains("not a directory"))
        #expect(problem.fix.contains("mv '\(config)'"))
    }
}
#endif

#if os(Linux)
/// A directory under the fixture for `XDG_RUNTIME_DIR` to name.
private func makeRuntimeDirectory(_ fixture: InstallHome, mode: Int) throws -> String {
    let path = fixture.root.path + "/runtime"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    return path
}

/// The fix for an `XDG_RUNTIME_DIR` that is not this user's uid-derived
/// directory: never chown or chmod it (it may be a shared directory such as
/// `/tmp`, or another user's runtime directory under `sudo -E`).
private let dialed = "rvd refuses this directory (XDG_RUNTIME_DIR here: the directory this shell and its agents dial)"

private func elsewhereFix(_ userID: uid_t) -> String {
    "set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents, "
        + "or unset it (rvd then uses /run/user/\(userID))"
}

/// rvd refuses a runtime directory that group or others can write, or
/// that another uid owns (`UnixSocketPath.prepareRuntime`).
@Test func doctorInstall_linuxUnsafeRuntimeDirectory_failsNamingIt() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let runtime = try makeRuntimeDirectory(fixture, mode: 0o770)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: runtime)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.severity == .fail)
        #expect(problem.summary == "\(runtime) is group/world-writable (mode 770); \(dialed)")
        #expect(problem.fix == elsewhereFix(getuid()))
        #expect(problem.fix.contains("chmod") == false)
        #expect(doctorPretty(fixture).exitCode == 1)
    }
    try withInstallHome(userID: getuid() + 1) { fixture in
        try stageHealthyInstall(fixture)
        let runtime = try makeRuntimeDirectory(fixture, mode: 0o700)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: runtime)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.summary.contains("\(runtime) is owned by uid \(getuid()), not uid \(getuid() + 1)"))
        #expect(problem.fix == elsewhereFix(getuid() + 1))
        #expect(problem.fix.contains("chown") == false)
    }
}

/// XDG_RUNTIME_DIR unset and no login manager made `/run/user/<uid>`:
/// rvd cannot create it without root, so doctor gives rvd's root fix.
@Test func doctorInstall_linuxMissingUserRuntimeDirectory_givesRootFix() throws {
    try withInstallHome(userID: 4242) { fixture in
        try stageHealthyInstall(fixture)
        let root = fixture.root.path + "/run-user"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: nil, userRuntimeRoot: root)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.severity == .fail)
        #expect(problem.summary == "\(root)/4242 is missing and only root can create it; rvd refuses to start")
        #expect(problem.fix.hasPrefix("as root, mkdir -p -m 0700 \(root)/4242 && chown 4242 \(root)/4242; "))
    }
}

/// XDG_RUNTIME_DIR set but empty is fail-closed in rvd.
@Test func doctorInstall_linuxEmptyXDGRuntimeDir_saysRvdRefuses() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: "")
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.summary
            == "XDG_RUNTIME_DIR is set but empty; rvd refuses it, and this shell and its agents cannot dial rvd")
        #expect(problem.fix.hasPrefix("unset it (rvd then uses /run/user/\(getuid()))"))
    }
}

/// What rvd accepts: an existing uid-derived directory, and a missing
/// XDG_RUNTIME_DIR elsewhere (rvd creates that one itself).
@Test func doctorInstall_linuxRuntimeDirectoryRvdAccepts_addsNoProblem() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let root = fixture.root.path + "/run-user"
        let owner = root + "/\(getuid())"
        try FileManager.default.createDirectory(atPath: owner, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: owner)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: nil, userRuntimeRoot: root)
        #expect(problems(fixture).isEmpty)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: fixture.root.path + "/absent")
        #expect(problems(fixture).isEmpty)
        let readable = try makeRuntimeDirectory(fixture, mode: 0o755)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: readable)
        #expect(problems(fixture).isEmpty)
    }
}

/// Root may create a missing `/run/user/<uid>` (and `/run/user`), so rvd
/// starts as root and doctor stays silent.
@Test func doctorInstall_linuxMissingUserRuntimeDirectoryAsRoot_addsNoProblem() throws {
    try withInstallHome(userID: 0) { fixture in
        try stageHealthyInstall(fixture)
        let root = fixture.root.path + "/run-user"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: nil, userRuntimeRoot: root)
        #expect(problems(fixture).isEmpty)
    }
}

/// The user's own uid-derived directory is repaired in place. Tests cannot
/// chown, so "owned by root" is another uid owning it.
@Test func doctorInstall_linuxUnsafeUserRuntimeDirectory_isRepairedInPlace() throws {
    try withInstallHome(userID: getuid() + 1) { fixture in
        try stageHealthyInstall(fixture)
        let root = fixture.root.path + "/run-user"
        let base = root + "/\(getuid() + 1)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: nil, userRuntimeRoot: root)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.summary
            == "\(base) is owned by uid \(getuid()), not uid \(getuid() + 1); rvd refuses this directory")
        #expect(problem.fix == "sudo chown \(getuid() + 1) '\(base)'")
    }
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let root = fixture.root.path + "/run-user"
        let base = root + "/\(getuid())"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: base)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: nil, userRuntimeRoot: root)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.summary == "\(base) is group/world-writable (mode 770); rvd refuses this directory")
        #expect(problem.fix == "chmod go-w '\(base)'")
    }
}

/// rvd refuses a base that is a file, or a symlink even to a good
/// directory (it judges the link itself).
@Test func doctorInstall_linuxRuntimeDirectoryFileOrSymlink_isNotADirectory() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let file = fixture.root.path + "/runtime-file"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        let target = try makeRuntimeDirectory(fixture, mode: 0o700)
        let link = fixture.root.path + "/runtime-link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        for base in [file, link] {
            fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: base)
            let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
            #expect(problem.summary == "\(base) is not a directory; \(dialed)")
            #expect(problem.fix == elsewhereFix(getuid()))
        }
    }
}

/// A socket path past the `sockaddr_un` budget: rvd cannot bind it and
/// clients cannot dial it.
@Test func doctorInstall_linuxRuntimeDirectoryTooLong_saysRvdRefuses() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let long = "/" + String(repeating: "a", count: 120)
        fixture.environment.install?.socketBase = SocketBaseEnvironment(xdgRuntimeDir: long)
        let problem = try #require(problems(fixture).first { $0.id == "runtime-dir" })
        #expect(problem.summary == "rvd's socket path under \(long) is too long for a Unix socket; "
            + "rvd refuses it, and this shell and its agents cannot dial rvd")
        #expect(problem.fix == "set XDG_RUNTIME_DIR to a directory only you can access, for rvd and for your agents, "
            + "with a shorter path, or unset it (rvd then uses /run/user/\(getuid()))")
    }
}
#endif

@Test func doctorInstall_packBundleMissingNextToRvd_failsWithReinstall() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        try FileManager.default.removeItem(
            atPath: (fixture.paths.localRvd as NSString).deletingLastPathComponent + "/" + DoctorInstallChecks.packBundleName
        )
        let problem = try #require(problems(fixture).first { $0.id == "pack-bundle" })
        #expect(problem.severity == .fail)
        #expect(problem.fix.contains("reinstall rv"))
    }
}

#if !canImport(Darwin)
/// Swift 6.4's default build system emits `rv_RVPacks.bundle` on Linux; the
/// legacy native build system emits `rv_RVPacks.resources`. Either is a
/// loadable install (PackRegistry accepts both), so neither may fail doctor.
@Test func doctorInstall_linuxLegacyResourcesBundle_isAccepted() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let binDirectory = (fixture.paths.localRvd as NSString).deletingLastPathComponent
        try FileManager.default.moveItem(
            atPath: binDirectory + "/rv_RVPacks.bundle",
            toPath: binDirectory + "/rv_RVPacks.resources"
        )
        #expect(problems(fixture).contains { $0.id == "pack-bundle" } == false)
    }
}
#endif

@Test func doctorInstall_rvdMissing_failsWithReinstall() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        try FileManager.default.removeItem(atPath: fixture.paths.localRvd)
        let problem = try #require(problems(fixture).first { $0.id == "rvd-missing" })
        #expect(problem.summary.contains(fixture.paths.localRvd))
        #expect(problem.fix.contains("reinstall rv"))
        #expect(problems(fixture).contains { $0.id == "pack-bundle" } == false)
    }
}

/// The incident: a valid admin manifest pins a Developer ID rvd, the
/// installed rvd is a local ad-hoc build, every hook call is denied.
private let adHocUnderManifest = DoctorServiceTrust(
    source: "manifest",
    satisfied: false,
    reason: "manifest requires Developer ID dev.rv.rvd (team 5V273URY46); installed rvd is ad-hoc signed"
)

@Test func doctorInstall_untrustedRvdUnderManifest_namesReasonAndBothRemediations() throws {
    try withInstallHome(trustManifest: .valid, daemonTrust: adHocUnderManifest) { fixture in
        try stageHealthyInstall(fixture)
        let problem = try #require(problems(fixture).first { $0.id == "daemon-trust" })
        #expect(problem.severity == .fail)
        #expect(problem.summary.contains("ad-hoc signed"))
        #expect(problem.summary.contains("hooks deny every tool call"))
        #expect(problem.fix.contains("RV_RELEASE_SIGN=1 Scripts/release.sh"))
        #expect(problem.fix.contains("sudo rm '/Library/Application Support/RV/peer-trust.json'"))
        let outcome = doctorPretty(fixture)
        #expect(outcome.stdout.contains(problem.summary))
        #expect(outcome.stdout.contains("fix: \(problem.fix)"))
        #expect(outcome.exitCode == 1)
    }
}

@Test func doctorInstall_untrustedRvdUnderSiblingPin_pointsAtReinstall() throws {
    let unsigned = DoctorServiceTrust(
        source: "sibling-pin", satisfied: false,
        reason: "installed rvd has no valid code signature, so hooks cannot pin it"
    )
    try withInstallHome(daemonTrust: unsigned) { fixture in
        try stageHealthyInstall(fixture)
        let problem = try #require(problems(fixture).first { $0.id == "daemon-trust" })
        #expect(problem.fix.contains("reinstall rv"))
        #expect(problem.fix.contains("sudo") == false)
    }
}

/// An invalid manifest already has its own row; do not report it twice.
@Test func doctorInstall_invalidManifestIsReportedOnce() throws {
    let invalid = DoctorServiceTrust(
        source: "invalid", satisfied: false,
        reason: "trust manifest is present but rejected, so hooks reject every rvd"
    )
    try withInstallHome(trustManifest: .invalid, daemonTrust: invalid) { fixture in
        try stageHealthyInstall(fixture)
        let ids = problems(fixture).map(\.id)
        #expect(ids.contains("trust-manifest"))
        #expect(ids.contains("daemon-trust") == false)
    }
}

@Test func doctorInstall_trustedRvdAddsNoProblem() throws {
    let trusted = DoctorServiceTrust(source: "sibling-pin", satisfied: true, reason: nil)
    try withInstallHome(daemonTrust: trusted) { fixture in
        try stageHealthyInstall(fixture)
        #expect(problems(fixture).isEmpty)
        #expect(doctorPretty(fixture).exitCode == 0)
    }
}

@Test func doctorRobot_serviceTrustIsAdditive() throws {
    let rejected = ServiceDiagnosticResult.local(
        ServiceFallbackDiagnostic(cause: .requestFailed(.daemonRejected), corePacksReady: true)
    )
    try withInstallHome(trustManifest: .valid, daemonTrust: adHocUnderManifest) { fixture in
        try stageHealthyInstall(fixture)
        let outcome = DoctorRun.run(environment: fixture.environment, diagnostics: rejected, appearance: .robot)
        let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
        let service = try #require(json["service"] as? [String: Any])
        #expect(service["state"] as? String == "down")
        #expect(service["warning"] as? String == "daemon identity rejected")
        let trust = try #require(service["trust"] as? [String: Any])
        #expect(trust["source"] as? String == "manifest")
        #expect(trust["satisfied"] as? Bool == false)
        #expect(trust["reason"] as? String == adHocUnderManifest.reason)
    }
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let outcome = DoctorRun.run(environment: fixture.environment, diagnostics: runningDiagnostics, appearance: .robot)
        #expect(outcome.stdout.contains("\"trust\"") == false)
    }
}

#if os(macOS)
/// Live probe wiring: the installed rvd is judged against the active trust
/// source, and a missing rvd is left to the `rvd-missing` row.
@Test func daemonTrustProbe_mapsVerdictAndSkipsMissingRvd() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-trust-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rvd = root.appendingPathComponent("rvd").path
    #expect(DaemonTrustProbe.evaluate(rvdPath: rvd, source: .siblingPin) == nil)
    try makeExecutable(URL(fileURLWithPath: rvd))
    #expect(DaemonTrustProbe.evaluate(rvdPath: rvd, source: .siblingPin) == DoctorServiceTrust(
        source: "sibling-pin", satisfied: false,
        reason: "installed rvd has no valid code signature, so hooks cannot pin it"
    ))
    #expect(DaemonTrustProbe.evaluate(rvdPath: rvd, source: .invalid)?.source == "invalid")
}
#endif

// MARK: - Rendering

@Test func doctorRender_everyProblemRowPrintsAFixLine() throws {
    try withInstallHome(
        launchd: LaunchdObservation(guiDomainExists: true, loadedInGui: false, loadedInUser: true),
        trustManifest: .invalid
    ) { fixture in
        try stageHealthyInstall(fixture)
        try writePlist(fixture, rvd: "/src/rv/.build/debug/rvd")
        let outcome = doctorPretty(fixture)
        let found = problems(fixture)
        #expect(found.count == 3)
        #expect(outcome.stdout.contains("Problems"))
        for problem in found {
            #expect(outcome.stdout.contains(problem.summary))
            #expect(outcome.stdout.contains("fix: \(problem.fix)"))
        }
        #expect(outcome.exitCode == 1)
    }
}

@Test func doctorRender_downServicePrintsRestartFix_andNoFallbackClaim() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let down = ServiceDiagnosticResult.local(ServiceFallbackDiagnostic(cause: .down, corePacksReady: true))
        let outcome = doctorPretty(fixture, down)
        #expect(outcome.stdout.contains("fix: \(DoctorRun.restartCommand)"))
        #expect(outcome.stdout.contains("\(fixture.paths.localRv) setup"))
        #expect(outcome.stdout.lowercased().contains("fallback") == false)
        #expect(outcome.exitCode == 1)
    }
}

@Test func doctorRender_notInstalledServicePrintsSetupFix() throws {
    try withInstallHome(launchd: LaunchdObservation(guiDomainExists: true, loadedInGui: false, loadedInUser: false)) { fixture in
        let down = ServiceDiagnosticResult.local(ServiceFallbackDiagnostic(cause: .down, corePacksReady: true))
        let outcome = doctorPretty(fixture, down)
        #expect(outcome.stdout.contains("not installed"))
        #expect(outcome.stdout.contains("fix: run \(fixture.paths.localRv) setup"))
    }
}

@Test func doctorRender_rejectedDaemonIdentityPointsAtSetup() throws {
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let rejected = ServiceDiagnosticResult.local(
            ServiceFallbackDiagnostic(cause: .requestFailed(.daemonRejected), corePacksReady: true)
        )
        let outcome = doctorPretty(fixture, rejected)
        #expect(outcome.stdout.contains("daemon identity rejected"))
        #expect(outcome.stdout.contains("fix: run \(fixture.paths.localRv) setup, then \(DoctorRun.restartCommand)"))
    }
}

@Test func doctorRobot_listsProblemsOnlyWhenPresent() throws {
    try withInstallHome(trustManifest: .invalid) { fixture in
        try stageHealthyInstall(fixture)
        let outcome = DoctorRun.run(environment: fixture.environment, diagnostics: runningDiagnostics, appearance: .robot)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any]
        )
        let rows = try #require(json["problems"] as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == "trust-manifest")
        #expect(rows[0]["severity"] as? String == "fail")
        #expect((rows[0]["fix"] as? String)?.contains("sudo") == true)
        #expect(json["ok"] as? Bool == false)
    }
    try withInstallHome { fixture in
        try stageHealthyInstall(fixture)
        let outcome = DoctorRun.run(environment: fixture.environment, diagnostics: runningDiagnostics, appearance: .robot)
        #expect(outcome.stdout.contains("\"problems\"") == false)
        #expect(outcome.exitCode == 0)
    }
}

// MARK: - Probe route

/// Manifest-free install: the manifest-required session cannot verify rvd,
/// but the hook-consult session (sibling pin) can.
private final class ManifestlessTransport: ServiceTransport {
    let snapshot: DoctorSnapshotReply
    private let hookHellos = Mutex(0)

    init(snapshot: DoctorSnapshotReply) { self.snapshot = snapshot }

    var hookHelloCount: Int { hookHellos.withLock { $0 } }

    func hello(clientSemver _: String) async throws -> HelloAckView {
        throw ServiceTransportError.unexpected
    }

    func helloHookConsult(clientSemver _: String) async throws -> HelloAckView {
        hookHellos.withLock { $0 += 1 }
        return HelloAckView(protocolName: "rv.ipc.v1", serviceSemver: "1.0.0", status: .ok)
    }

    func send(_: Data) async throws -> Data {
        throw ServiceTransportError.unexpected
    }

    func sendHookConsult(_ body: Data, timeoutMs _: Int) async throws -> Data {
        let request = try IPCJSON.decode(IPCRequest.self, from: body)
        return try IPCJSON.encode(
            IPCResponse(id: request.id, protocolName: request.protocolName, result: .doctorSnapshot(snapshot))
        )
    }

    func invalidate() {}
}

@Test func diagnostics_probeDaemonTheWayHooksDo_soManifestFreeInstallIsUp() async throws {
    guard case .xpc(let snapshot, _) = runningDiagnostics else { return }
    let transport = ManifestlessTransport(snapshot: snapshot)
    let result = try await isolatedClient(transport: transport).diagnostics()
    #expect(result == .xpc(snapshot: snapshot, localCorePacksReady: true))
    #expect(transport.hookHelloCount == 1)
    let status = try await isolatedClient(transport: transport).status()
    #expect(status.state == "running")
}

#if canImport(XPC)
private struct ThrowingHelloTransport: ServiceTransport {
    let error: any Error & Sendable

    func hello(clientSemver _: String) async throws -> HelloAckView { throw error }
    func helloHookConsult(clientSemver _: String) async throws -> HelloAckView { throw error }
    func send(_: Data) async throws -> Data { throw error }
    func invalidate() {}
}

@Test func diagnostics_xpcConnectFailureIsDown_notRequestFailed() async throws {
    let result = try await isolatedClient(
        transport: ThrowingHelloTransport(error: XPCEvaluateClientError.connectFailed)
    ).diagnostics()
    #expect(result == .local(.init(cause: .down, corePacksReady: true)))
}

@Test func diagnostics_daemonIdentityRejectionIsTyped() async throws {
    let result = try await isolatedClient(
        transport: ThrowingHelloTransport(error: XPCEvaluateClientError.authenticationFailed)
    ).diagnostics()
    #expect(result == .local(.init(cause: .requestFailed(.daemonRejected), corePacksReady: true)))
    #expect(ServiceDiagnosticFailure.daemonRejected.statusMessage == "daemon identity rejected")
}
#endif

#if os(Linux)
/// With XDG_RUNTIME_DIR unset the CLI dials the uid-derived socket; a miss
/// there is rvd being down, not a failed request.
@Test func diagnostics_ownerRuntimeSocketMissIsDown_notRequestFailed() async throws {
    let missing = "/tmp/rv-miss-\(UUID().uuidString.prefix(8))/rv/evaluate.sock"
    let transport = UnixSocketServiceTransport(socketPath: missing, ownerRuntimeSocket: true)
    let result = try await isolatedClient(transport: transport).diagnostics()
    #expect(result == .local(.init(cause: .down, corePacksReady: true)))
}
#endif
