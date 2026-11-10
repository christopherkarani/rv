import RVDomain
import RVEngine
import RVPolicy

/// What observe mode never relaxes: rv's own protection.
///
/// An observe host allows and records what enforcement would deny, but it
/// must not be able to loosen another host or the global guard. So an rv
/// admin command that weakens rv or stops rvd (`SelfProtectionGuard`), a
/// write to rv's install (`RVInstallPathGuard`: rvd's binaries, LaunchAgent,
/// systemd unit, socket dir), or a touch of rv's config dir
/// (`core.secrets:home-rv-config`, the only catalog rule that guards rv's
/// own state) stays enforced. `GatedEvaluate.posture` is the
/// only caller; it then runs the enforce branch, so the verdict is exactly
/// what an enforced host would get.
enum ObserveFloor {
    static let ruleIDs: Set<RuleID> = [RuleID(pack: .coreSecrets, pattern: "home-rv-config")]

    private static let catalog = SecretPathCatalog(
        rules: SecretPathCatalog.dayOne.rules.filter { ruleIDs.contains(SecretPathMatch($0).ruleID) }
    )

    /// File door: the one path's verdict says it.
    static func holds(_ result: EvaluationResult) -> Bool {
        switch result.decision {
        case .indeterminate(.selfProtection):
            true
        case .deny(let deny):
            ruleIDs.contains(deny.ruleID)
        case .allow, .indeterminate:
            false
        }
    }

    /// Shell doors: the verdict, then the command itself. A pack deny is
    /// terminal, so `git reset --hard; rv host mode cursor off` reports only
    /// the git rule, and `echo x > ~/.config/rv/config.json` only a redirect
    /// rule; observing that deny would run the rest too. So every word of
    /// the command (raw and normalized, split at shell punctuation) is also
    /// checked as an rv-config path, with the door's exemptions and alias
    /// resolution.
    static func holds(
        _ result: EvaluationResult,
        command: ShellCommand,
        store: PolicyStoreInputs,
        home: HomeDirectory?,
        cwd: WorkingDirectory?
    ) -> Bool {
        if holds(result) || SelfProtectionGuard.weakensPolicy(command)
            || RVInstallPathGuard.touchesInstall(command, home: home, cwd: cwd) {
            return true
        }
        let rvConfig = SecretPathDecider(
            catalog: catalog,
            safety: store.safety,
            allowPaths: store.allowPaths.effective,
            home: home,
            resolution: SecretPathCandidateResolver.resolution(home: home, cwd: cwd)
        )
        let words = Set([command.rawValue, result.matchingView.rawValue].flatMap { text in
            text.split(whereSeparator: { wordBreaks.contains($0) }).map(String.init)
        })
        return words.contains { rvConfig.filePathHit($0) != nil }
    }

    private static let wordBreaks: Set<Character> = [
        " ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "<", ">", "'", "\"", "`", "=", ",",
    ]
}
