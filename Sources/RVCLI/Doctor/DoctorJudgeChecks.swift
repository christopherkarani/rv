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

    /// `rv-judge` is installed and a valid manifest omits the `judge` role.
    static func lacksJudge(paths: OwnedPaths, manifestRoles: Set<String>?) -> Bool {
        guard let manifestRoles,
              FileManager.default.isExecutableFile(atPath: SetupRun.judgeExecutable(rvdPath: paths.localRvd))
        else { return false }
        return manifestRoles.contains("judge") == false
    }

    /// With a judge bundle installed (macOS), the pool agent must be
    /// installed beside rvd, registered and loaded. `loaded` is nil when
    /// launchd was not observed: nothing to say then.
    static func agent(
        paths: OwnedPaths,
        fileManager: FileManager,
        loaded: Bool?,
        bundleInstalled: Bool
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
        return nil
    }
}
