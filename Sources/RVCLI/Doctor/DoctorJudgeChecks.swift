#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIPC
import RVPresentation

/// Doctor's judge rows. Both are warnings: a judge that cannot answer sends
/// judged calls to review (never to allow), so hooks still gate.
enum DoctorJudgeChecks {
    /// rvd's own judge and judge-pool warnings, so the human output shows
    /// what `--json` already carries.
    static func serviceWarnings(_ diagnostics: ServiceDiagnosticResult) -> [DoctorProblem] {
        guard case .xpc(let snapshot, _) = diagnostics else { return [] }
        return snapshot.checks.compactMap { check in
            guard check.status == .warning else { return nil }
            switch check.id {
            case .judge:
                return DoctorProblem(
                    id: "judge", severity: .warn, summary: check.message,
                    fix: "reinstall the judge bundle, or remove it to run packs only")
            case .judgePool:
                return DoctorProblem(id: "judge-pool", severity: .warn, summary: check.message, fix: "rv setup")
            default:
                return nil
            }
        }
    }

    /// An installed manifest with no `judge` entry verifies no supervisor:
    /// rvd treats the pool as unreachable.
    static func manifestRole(lacksJudge: Bool) -> DoctorProblem? {
        guard lacksJudge else { return nil }
        return DoctorProblem(
            id: "peer-trust-judge-role-missing", severity: .warn,
            summary: "the peer-trust manifest at \(DoctorInstallChecks.trustManifestPath) has no judge entry; "
                + "rvd verifies no judge pool, so judged calls go to review",
            fix: "add a judge entry for the installed rv-judge to '\(DoctorInstallChecks.trustManifestPath)'; "
                + "the file is root-owned, so this needs an administrator (sudo)")
    }

    /// rv's config dir and the judge's cache below it
    /// (`cache/laya/models`, the verified compiled models and Core ML crash
    /// markers) must be this user's and writable by no one else: another
    /// account that can write there can swap a level for its own and plant
    /// a model or a crash history. Names every level that is not; missing
    /// levels are fine (created owner-only on first use). The config dir
    /// may be a link (dotfile managers), so it is followed; the cache levels
    /// never are.
    static func cacheExposure(configDirectory: String) -> DoctorProblem? {
        let levels = [
            (configDirectory, true),
            (configDirectory + "/cache", false),
            (configDirectory + "/cache/laya", false),
            (configDirectory + "/cache/laya/models", false),
        ]
        let exposed = levels.compactMap { path, follow in exposure(path, follow: follow).map { "\(path) (\($0))" } }
        guard !exposed.isEmpty else { return nil }
        return DoctorProblem(
            id: "judge-cache-exposed", severity: .warn,
            summary: "writable by another account: \(exposed.joined(separator: "; ")); "
                + "it could replace the judge's compiled model or crash history",
            fix: "chown -R \(NSUserName()) '\(configDirectory)' && chmod go-w '\(configDirectory)' "
                + "'\(configDirectory)/cache' '\(configDirectory)/cache/laya' '\(configDirectory)/cache/laya/models'")
    }

    /// Why `path` is exposed, or nil when it is missing or a directory of
    /// this user that no one else can write.
    static func exposure(_ path: String, follow: Bool) -> String? {
        var info = stat()
        let found = follow ? stat(path, &info) : lstat(path, &info)
        guard found == 0 else { return errno == ENOENT ? nil : "unreadable" }
        if info.st_mode & S_IFMT == S_IFLNK { return "a symlink" }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "not a directory" }
        guard info.st_uid == geteuid() else { return "owned by uid \(info.st_uid)" }
        let mode = info.st_mode & 0o777
        guard mode & 0o022 == 0 else { return "mode \(String(mode, radix: 8))" }
        return nil
    }

    /// `rv-judge` is installed and a valid manifest omits the `judge` role.
    static func lacksJudge(paths: OwnedPaths, manifestRoles: Set<String>?) -> Bool {
        guard let manifestRoles,
              FileManager.default.isExecutableFile(atPath: SetupRun.judgeExecutable(rvdPath: paths.localRvd))
        else { return false }
        return manifestRoles.contains("judge") == false
    }

    /// With a judge bundle installed (macOS), the pool agent must be
    /// installed beside rvd, registered and loaded, always on (RunAtLoad +
    /// KeepAlive, as rvd's), and loaded in one domain only. `loaded` is nil
    /// when launchd was not observed: nothing to say then.
    static func agent(
        paths: OwnedPaths,
        fileManager: FileManager,
        loaded: Bool?,
        bundleInstalled: Bool,
        loadedInBothDomains: Bool = false
    ) -> DoctorProblem? {
        guard bundleInstalled, let loaded else { return nil }
        let judge = SetupRun.judgeExecutable(rvdPath: paths.localRvd)
        guard fileManager.isExecutableFile(atPath: judge) else {
            return DoctorProblem(
                id: "judge-agent", severity: .warn,
                summary: "a judge bundle is installed but rv-judge is missing at \(judge); judged calls go to review",
                fix: SetupRun.reinstallHint)
        }
        guard fileManager.fileExists(atPath: paths.judgeLaunchAgent) else {
            return DoctorProblem(
                id: "judge-agent", severity: .warn,
                summary: "\(SetupRun.judgeLaunchAgentLabel) is not registered (\(paths.judgeLaunchAgent) missing); judged calls go to review",
                fix: "rv setup")
        }
        guard loaded else {
            return DoctorProblem(
                id: "judge-agent", severity: .warn,
                summary: "\(SetupRun.judgeLaunchAgentLabel) is not loaded; judged calls go to review",
                fix: "rv setup")
        }
        guard DoctorInstallChecks.launchAgentKeepsRvdUp(at: paths.judgeLaunchAgent, rvdPath: judge) else {
            return DoctorProblem(
                id: "judge-agent-on-demand", severity: .warn,
                summary: "LaunchAgent \(paths.judgeLaunchAgent) is not RunAtLoad + KeepAlive: after a crash "
                    + "the judge pool stays down until a judged call starts it, and that call goes to review",
                fix: "rv setup")
        }
        guard loadedInBothDomains == false else {
            return DoctorProblem(
                id: "judge-agent-duplicate", severity: .warn,
                summary: "\(SetupRun.judgeLaunchAgentLabel) is loaded in both the gui and user launchd domains, "
                    + "so launchd keeps two judge pools running",
                fix: "rv setup")
        }
        return nil
    }
}
