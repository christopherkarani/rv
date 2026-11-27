import Foundation
import RVDomain
import RVHooks
import RVIsolation
import RVPolicy

extension HouseRules {
    /// B4: the facts rv tells an agent at session start, read the way the
    /// shell door reads them, and only read. `environment` is the
    /// answering process's launch environment, which can only tighten the
    /// mode (`GuardModeResolution`), so the mode named is the one the
    /// door enforces.
    ///
    /// - Mode: this host's guard mode (organization pins included).
    /// - Repo rules: the deny and ask rules of `<cwd>/.rv`, if it loads.
    ///   A repo policy that does not load names no rules here; the door
    ///   fails closed on it anyway.
    /// - Keys: secret names `rv run --secret` will deliver (not scoped to
    ///   other agents, not expired). Names only; no value is read.
    package static func gather(
        home: HomeDirectory?,
        cwd: WorkingDirectory?,
        host: HookHost,
        environment: [String: String],
        now: Date = Date()
    ) -> HouseRules {
        let mode = JudgeRuntime.effectiveGuardMode(
            home: home, host: .hook(host), environment: environment, config: GuardConfig.read(home: home))
        return HouseRules(
            mode: mode == .observe ? .watching : .guarding,
            repoRules: repoRules(cwd: cwd),
            keys: keys(home: home, now: now)
        )
    }

    private static func repoRules(cwd: WorkingDirectory?) -> [RepoRule] {
        guard let cwd else { return [] }
        let workspace = PolicyWorkspace(
            home: nil, workspace: URL(fileURLWithPath: cwd.rawValue, isDirectory: true))
        guard let document = try? workspace.loadRepoDocument() else { return [] }
        return document.rules.map { RepoRule(verdict: $0.verdict, id: $0.id) }
    }

    private static func keys(home: HomeDirectory?, now: Date) -> [String] {
        guard let home,
              case .success(let configuration) = SecretsConfiguration.load(
                configDirectory: RVPolicyPaths.configDirectory(home: home))
        else { return [] }
        return configuration.secrets
            .filter { $0.stages(forAgent: nil) && ($0.expires.map { $0 > now } ?? true) }
            .map(\.name)
    }
}
