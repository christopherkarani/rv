import Foundation
import RVDomain
import RVHistory
import RVPolicy

/// Engine choice for one evaluation, with its validated bundle.
struct JudgeSelection: Sendable, Equatable {
    let engine: JudgeEngine
    /// Nil when the selected engine's bundle is missing: packs-only with an
    /// `engine-missing` note, never fail-closed.
    let bundle: URL?
}

/// Policy-store state for one (home, workspace). Package-script bodies that
/// run in another package directory gather their own.
struct PolicyStoreInputs: Sendable {
    let allowPaths: SecretAllowPaths.EffectiveAllowPaths
    /// Nil when typed rules failed to load: the door fails closed.
    let policy: EffectiveActionPolicy?
    let safety: SafetyLevel
    /// Non-nil while rv's MCP gateway is in use (`MCPHostConfigDoor`):
    /// the shell door's probed context carries it so host MCP config
    /// writes deny.
    var mcpHostConfigGuard: MCPHostConfigGuard? = nil

    /// Read order matches the pre-T6 door: allow-paths, typed rules, safety.
    /// Typed rules: machine from `$HOME/.config/rv`, repo from `<cwd>/.rv`;
    /// missing HOME skips machine and still loads repo when cwd is present.
    static func gather(home: HomeDirectory?, cwd: WorkingDirectory?) -> PolicyStoreInputs {
        let workspace = cwd.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
        let allowPaths = SecretAllowPaths.loadEffectiveDetailed(home: home, workspace: workspace)
        let policy = try? EffectiveActionPolicy(
            rules: PolicyWorkspace(home: home, workspace: workspace).loadEffectiveRules(builtin: [])
        )
        // The organization's gate can only raise safety to strict.
        let safety = ManagedGate.safety(SafetyStore.loadEffective(home: home, workspace: workspace), home: home)
        return PolicyStoreInputs(
            allowPaths: allowPaths, policy: policy, safety: safety,
            mcpHostConfigGuard: MCPHostConfigDoor.hostConfigGuard(home: home, managed: ManagedGate.state(home: home)))
    }
}

/// Everything the gated door reads from env, `config.json`, bundles, and
/// policy stores, read once per evaluation. No write earlier in an evaluation
/// can change any of these. See the T6 audit for the reads that stay lazy at
/// their call sites (rebase probe, allowlist, package scripts, judge context,
/// denial-ledger preference).
struct EvaluationInputs: Sendable {
    let guardMode: GuardMode
    let judge: JudgeSelection
    let store: PolicyStoreInputs

    /// `environment` is explicit; the door's public entry points pass
    /// `ProcessInfo.processInfo.environment`. It can only tighten the guard
    /// mode; engine selection never reads it. `config.json` is parsed once
    /// and shared by guard mode and engine selection. `host` selects the
    /// per-host guard entry (`tty` has none).
    static func gather(
        home: HomeDirectory?,
        cwd: WorkingDirectory?,
        environment: [String: String],
        host: LedgerHost = .tty
    ) -> EvaluationInputs {
        let config = JudgeRuntime.loadConfigDict(home: home)
        return EvaluationInputs(
            // The organization's gate pins enforce mode while it applies.
            guardMode: JudgeRuntime.effectiveGuardMode(
                home: home, host: host, environment: environment, config: config),
            judge: JudgeRuntime.selection(home: home, config: config),
            store: .gather(home: home, cwd: cwd)
        )
    }
}
