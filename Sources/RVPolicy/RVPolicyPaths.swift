import Foundation
import RVDomain

public enum RVPolicyPaths: Sendable {
    public static func allowlistFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allowlist.toml", isDirectory: false)
    }

    public static func allowOnceFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("allow-once.jsonl", isDirectory: false)
    }

    public static func laPromptBudgetFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("la-prompt-budget.json", isDirectory: false)
    }

    public static func attestedEpochFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("attested-epoch.json", isDirectory: false)
    }

    public static func allowOnceLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".allow-once.lock", isDirectory: false)
    }

    public static func allowlistLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".allowlist.lock", isDirectory: false)
    }

    public static func denylistFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("denylist.toml", isDirectory: false)
    }

    public static func denylistLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".denylist.lock", isDirectory: false)
    }

    public static func pendingApprovalsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("pending-approvals.jsonl", isDirectory: false)
    }

    public static func pendingApprovalsLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".pending-approvals.lock", isDirectory: false)
    }

    public static func typedRulesFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("typed-rules.json", isDirectory: false)
    }

    public static func typedRulesLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".typed-rules.lock", isDirectory: false)
    }

    public static func policyFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("policy.toml", isDirectory: false)
    }

    public static func policyLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".policy.lock", isDirectory: false)
    }

    /// Append-only machine revision log. Every `policy.toml` save appends one
    /// JSON line; rollback appends a new head, never rewrites.
    public static func policyRevisionsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("policy-revisions.jsonl", isDirectory: false)
    }

    /// F1: HMAC-chained machine revision log (JSONL, one record per line).
    /// Machine layer only.
    public static func policyRevisionLogFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("policy-revisions.log", isDirectory: false)
    }

    /// F1: 32-byte log key, owner-only. Minted on first sealed save.
    public static func policyRevisionLogKeyFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".policy-revisions.key", isDirectory: false)
    }

    /// F1: MAC-sealed tip (`{"revision","tip","mac"}`). Makes truncation
    /// detectable: a shortened chain no longer matches the sealed tip.
    public static func policyRevisionLogTipFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".policy-revisions.tip", isDirectory: false)
    }

    public static func policyRevisionLogLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(".policy-revisions.lock", isDirectory: false)
    }

    /// F5: last proxy-accepted live rule set, written by the supervisor
    /// after each accepted push. Display status for `rv egress`; the
    /// proxy never reads it back.
    public static func egressLoadedSnapshotFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("egress-loaded.json", isDirectory: false)
    }

    public static func egressDenialsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("egress-denials.jsonl", isDirectory: false)
    }

    public static func pendingRejectionReasonsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(
            "pending-rejection-reasons.jsonl", isDirectory: false)
    }

    public static func pendingRejectionReasonsLockFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent(
            ".pending-rejection-reasons.lock", isDirectory: false)
    }

    public static func exemptionDropsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("exemption-drops.jsonl", isDirectory: false)
    }

    public static func exemptionDropsLockFile(inConfigDir configDir: URL) -> URL {
        exemptionDropsFile(inConfigDir: configDir).appendingPathExtension("lock")
    }

    public static func exemptionDropsTempFile(inConfigDir configDir: URL) -> URL {
        exemptionDropsFile(inConfigDir: configDir).appendingPathExtension("tmp")
    }

    /// Append-only repo revision log for one workspace. Lives in the machine
    /// config dir — never in the workspace `.rv/` dir a caged writer
    /// controls — under a name derived from the workspace path, so rollback
    /// targets are not forgeable by the writer they constrain. One file per
    /// workspace; the JSONL line format matches the machine log.
    public static func repoRevisionsFile(inConfigDir configDir: URL, workspace: URL) -> URL {
        let digest = RVDigest.sha256Hex(Array(workspace.path.utf8))
        return configDir.appendingPathComponent(
            "repo-revisions-\(digest.prefix(16)).jsonl", isDirectory: false
        )
    }

    /// Repo revision logs present in the config dir, for uninstall.
    /// Best-effort: names are dynamic per workspace.
    public static func repoRevisionLogs(inConfigDir configDir: URL) -> [URL] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: configDir.path)) ?? []
        return names
            .filter { $0.hasPrefix("repo-revisions-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { configDir.appendingPathComponent($0, isDirectory: false) }
    }

    public static func runtimeResourcesFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("runtime-resources.json", isDirectory: false)
    }

    public static func agentDefinitionsFile(inConfigDir configDir: URL) -> URL {
        configDir.appendingPathComponent("agent-definitions.json", isDirectory: false)
    }

    /// Files T6 / `rv uninstall` must delete when present (policy artifacts + locks).
    public static func uninstallArtifacts(inConfigDir configDir: URL) -> [URL] {
        [
            allowlistFile(inConfigDir: configDir),
            allowOnceFile(inConfigDir: configDir),
            allowOnceLockFile(inConfigDir: configDir),
            laPromptBudgetFile(inConfigDir: configDir),
            attestedEpochFile(inConfigDir: configDir),
            allowlistLockFile(inConfigDir: configDir),
            denylistFile(inConfigDir: configDir),
            denylistLockFile(inConfigDir: configDir),
            pendingApprovalsFile(inConfigDir: configDir),
            pendingApprovalsLockFile(inConfigDir: configDir),
            egressLoadedSnapshotFile(inConfigDir: configDir),
            egressDenialsFile(inConfigDir: configDir),
            pendingRejectionReasonsFile(inConfigDir: configDir),
            pendingRejectionReasonsLockFile(inConfigDir: configDir),
            exemptionDropsFile(inConfigDir: configDir),
            exemptionDropsLockFile(inConfigDir: configDir),
            exemptionDropsTempFile(inConfigDir: configDir),
            typedRulesFile(inConfigDir: configDir),
            typedRulesLockFile(inConfigDir: configDir),
            policyFile(inConfigDir: configDir),
            policyLockFile(inConfigDir: configDir),
            policyRevisionsFile(inConfigDir: configDir),
            policyRevisionLogFile(inConfigDir: configDir),
            policyRevisionLogKeyFile(inConfigDir: configDir),
            policyRevisionLogTipFile(inConfigDir: configDir),
            policyRevisionLogLockFile(inConfigDir: configDir),
            runtimeResourcesFile(inConfigDir: configDir),
            agentDefinitionsFile(inConfigDir: configDir),
        ]
    }

    /// `$HOME/.config/rv` from process `HOME` only. Never reads `XDG_CONFIG_HOME`.
    public static func configDirectory(home: HomeDirectory) -> URL {
        URL(fileURLWithPath: home.rawValue, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }
}
