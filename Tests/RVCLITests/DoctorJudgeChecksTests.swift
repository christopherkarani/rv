import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
import RVTheme
import Testing
@testable import RVCLI

/// Doctor's judge rows: rvd's judge warnings reach the human output, and on
/// macOS a judge bundle with no running pool agent is named.
@Suite struct DoctorJudgeChecksTests {
    private func paths() throws -> (URL, OwnedPaths) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-doctor-judge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = try #require(HomeDirectory(validating: root.path))
        return (root, OwnedPaths(home: home))
    }

    private func touchExecutable(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func snapshot(_ checks: [DoctorCheck]) -> ServiceDiagnosticResult {
        .xpc(
            snapshot: DoctorSnapshotReply(
                serviceSemver: "1.0.0", state: .running, idleExitSeconds: 300, packsEnabled: [], checks: checks),
            localCorePacksReady: true)
    }

    @Test func serviceJudgeWarningsBecomeProblems() {
        let problems = DoctorJudgeChecks.serviceWarnings(snapshot([
            DoctorCheck(id: .packs, status: .warning, message: "not mine"),
            DoctorCheck(id: .judge, status: .warning, message: "laya-ft bundle invalid at /m: tokenizer"),
            DoctorCheck(id: .judgePool, status: .warning, message: "judge pool unreachable"),
            DoctorCheck(id: .judgePool, status: .ok, message: "workers fine"),
        ]))
        #expect(problems.map(\.id) == ["judge", "judge-pool"])
        #expect(problems.allSatisfy { $0.severity == .warn })
        #expect(problems[0].summary.contains("tokenizer"))
        #expect(problems[1].summary.contains("unreachable"))
        #expect(problems[1].fix == "rv setup")
    }

    @Test func noWarningsFromALocalDiagnostic() {
        #expect(DoctorJudgeChecks.serviceWarnings(.local(ServiceFallbackDiagnostic(cause: .down, corePacksReady: true))).isEmpty)
    }

    @Test func agentIsNotCheckedWithoutABundle() throws {
        let (root, layout) = try paths()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: false, bundleInstalled: false) == nil)
    }

    @Test func bundleWithoutRvJudgeIsAWarning() throws {
        let (root, layout) = try paths()
        defer { try? FileManager.default.removeItem(at: root) }
        let problem = try #require(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: false, bundleInstalled: true))
        #expect(problem.id == "judge-agent")
        #expect(problem.severity == .warn)
        #expect(problem.summary.contains("rv-judge"))
        #expect(problem.summary.contains("review"))
    }

    @Test func rvJudgeWithoutAgentOrNotLoadedIsAWarning() throws {
        let (root, layout) = try paths()
        defer { try? FileManager.default.removeItem(at: root) }
        try touchExecutable(SetupRun.judgeExecutable(rvdPath: layout.localRvd))
        let unregistered = try #require(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: false, bundleInstalled: true))
        #expect(unregistered.summary.contains(layout.judgeLaunchAgent))
        #expect(unregistered.fix == "rv setup")

        try FileManager.default.createDirectory(
            atPath: (layout.judgeLaunchAgent as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "<plist/>".write(toFile: layout.judgeLaunchAgent, atomically: true, encoding: .utf8)
        let unloaded = try #require(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: false, bundleInstalled: true))
        #expect(unloaded.summary.contains("not loaded"))
        #expect(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: true, bundleInstalled: true) == nil)
        #expect(DoctorJudgeChecks.agent(
            paths: layout, fileManager: .default, loaded: nil, bundleInstalled: true) == nil,
            "launchd not observed (Linux, tests): nothing to say")
    }
    @Test func humanDoctorPrintsThePoolWarningOnceWithTheAgentCause() throws {
        let (root, layout) = try paths()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = DoctorEnvironment(
            home: layout.home, pathEntries: [], fileManager: .default, launchAgentLoaded: true,
            install: {
                var probes = DoctorInstallProbes(userID: getuid(), launchd: nil, trustManifest: .notApplicable)
                probes.judgeLoaded = false
                probes.judgeBundleInstalled = true
                return probes
            }())
        let diagnostics = snapshot([
            DoctorCheck(id: .judgePool, status: .warning, message: "judge pool unreachable or unverified"),
        ])
        let outcome = DoctorRun.run(environment: environment, diagnostics: diagnostics, appearance: .pretty(colorOffPalette))
        #expect(outcome.stdout.contains("rv-judge is missing"))
        #expect(outcome.stdout.contains("judge pool unreachable") == false, "the agent row names the cause")

        let noAgentIssue = DoctorEnvironment(
            home: layout.home, pathEntries: [], fileManager: .default, launchAgentLoaded: true)
        let plain = DoctorRun.run(environment: noAgentIssue, diagnostics: diagnostics, appearance: .pretty(colorOffPalette))
        #expect(plain.stdout.contains("judge pool unreachable or unverified"))
        #expect(plain.stdout.contains("fix: rv setup"))
    }
}
