import RVDomain
import RVEngine
import RVPolicy

/// What observe mode never relaxes: rv's own protection.
///
/// An observe host allows and records what enforcement would deny, but it
/// must not be able to loosen another host or the global guard. So an rv
/// admin command that weakens rv (`SelfProtectionGuard`), a touch of rv's
/// config dir (`core.secrets:home-rv-config`, the only catalog rule that
/// guards rv's own state) or of rv's wiring files (`RVWiringPaths`) stays
/// enforced. `GatedEvaluate.posture` is the
/// only caller; it then runs the enforce branch, so the verdict is exactly
/// what an enforced host would get.
///
/// Observe alone also floors stopping rvd (`RVDStopGuard`) and writing
/// rv's install (`RVInstallPathGuard`): with rvd absent an observe hook
/// allows every later call unchecked. In enforce a stopped rvd fails
/// closed, so those floors would only add false positives there.
enum ObserveFloor {
    static let ruleIDs: Set<RuleID> = [RuleID(pack: .coreSecrets, pattern: "home-rv-config"), RVWiringPaths.ruleID]

    private static let catalog = SecretPathCatalog(
        rules: SecretPathCatalog.dayOne.rules.filter { ruleIDs.contains(SecretPathMatch($0).ruleID) }
    )

    /// File door: the one path's verdict says it.
    static func holds(_ result: EvaluationResult) -> Bool {
        switch result.decision {
        case .indeterminate(.selfProtection):
            true
        case .deny(let deny):
            ruleIDs.contains(deny.ruleID) || hitsFloorTarget(result.analysis)
        case .allow, .indeterminate:
            false
        }
    }

    /// The shell door reports a wiring or rv-config write as the generic
    /// protected-path rule; the analysis still names the target's match.
    private static func hitsFloorTarget(_ analysis: SemanticAnalysis) -> Bool {
        guard let action = analysis.filesystemAction, action.operationKind != .read else { return false }
        return action.targets.contains { target in
            target.protectedMatch.map { ruleIDs.contains($0.ruleID) } ?? false
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
        if holds(result) || SelfProtectionGuard.weakensPolicy(command, rvdPIDs: runningRVDaemonPIDs) { return true }
        let rvConfig = SecretPathDecider(
            catalog: catalog,
            safety: store.safety,
            allowPaths: store.allowPaths.effective,
            home: home,
            resolution: SecretPathCandidateResolver.resolution(home: home, cwd: cwd)
        )
        // Also the command with quotes removed, so `"$HOME"/.claude/x`
        // reads as one word.
        let unquoted = command.rawValue.filter { $0 != "'" && $0 != "\"" }
        let words = Set([command.rawValue, unquoted, result.matchingView.rawValue].flatMap { text in
            text.split(whereSeparator: { wordBreaks.contains($0) }).map(String.init)
        })
        return words.contains { rvConfig.filePathHit($0) != nil || namesWiring($0, home: home, cwd: cwd) }
    }

    /// A word naming one of rv's wiring files (`RVWiringPaths`): the shell
    /// door enforces writes there, so an observe host must too. Reads are
    /// allowed under enforce anyway.
    /// The word is normalised first (`~`/`$HOME`/`~user` expanded, joined
    /// to the cwd, `.`/`..` collapsed). Host settings files at any scope
    /// count: a project one can disable hooks for every host.
    private static func namesWiring(_ word: String, home: HomeDirectory?, cwd: WorkingDirectory?) -> Bool {
        if RVWiringPaths.isHostSettingsFile(word) { return true }
        guard let home else { return false }
        let path = lexicalFilesystemPath(word, workingDirectory: cwd, homeDirectory: home)
        return RVWiringPaths.matches(path, home: home.rawValue)
    }

    /// Observe only: nil unless the command stops rvd or writes rv's
    /// install. Then an allow becomes "run it in Terminal"; anything else
    /// (a deny, an indeterminate) is kept, so the floor never weakens.
    static func lifecycleFloor(
        _ result: EvaluationResult, command: ShellCommand, home: HomeDirectory?, cwd: WorkingDirectory?
    ) -> EvaluationResult? {
        guard RVDStopGuard.stopsRVD(command.rawValue)
            || RVInstallPathGuard.touchesInstall(command, home: home, cwd: cwd) else { return nil }
        return floored(result)
    }

    /// File door: a write or edit of rv's install, typed or resolved.
    static func lifecycleFloor(
        _ result: EvaluationResult, action: FileToolAction, home: HomeDirectory?, cwd: WorkingDirectory?
    ) -> EvaluationResult? {
        guard action.kind != .read else { return nil }
        let resolution = SecretPathCandidateResolver.resolution(home: home, cwd: cwd)
        guard RVInstallPathGuard.writesInstall(action.path.rawValue, resolution: resolution, home: home) else {
            return nil
        }
        return floored(result)
    }

    private static func floored(_ result: EvaluationResult) -> EvaluationResult {
        guard result.decision == .allow else { return result }
        return EvaluationResult(outcome: .indeterminate(.selfProtection), matchingView: result.matchingView)
    }

    private static let wordBreaks: Set<Character> = [
        " ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "<", ">", "'", "\"", "`", "=", ",",
    ]
}
