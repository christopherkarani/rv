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
