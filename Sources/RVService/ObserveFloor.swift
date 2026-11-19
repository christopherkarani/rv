import RVDomain
import RVEngine
import RVPolicy

/// What observe mode never relaxes: rv's own protection.
///
/// An observe host allows and records what enforcement would deny, but it
/// must not be able to loosen another host or the global guard. So an rv
/// admin command that weakens rv (`SelfProtectionGuard`), a touch of rv's
/// config dir (`core.secrets:home-rv-config`, the only catalog rule that
/// guards rv's own state), of rv's Linux secret store
/// (`core.secrets:secret-service`) or of rv's wiring files (`RVWiringPaths`)
/// stays enforced. `GatedEvaluate.posture` is the
/// only caller; it then runs the enforce branch, so the verdict is exactly
/// what an enforced host would get.
///
/// Observe alone also floors stopping or retuning rvd (`RVDStopGuard`) and writing
/// rv's install (`RVInstallPathGuard`): with rvd absent an observe hook
/// allows every later call unchecked. In enforce a stopped rvd fails
/// closed, so those floors would only add false positives there.
enum ObserveFloor {
    static let ruleIDs: Set<RuleID> = [
        RuleID(pack: .coreSecrets, pattern: "home-rv-config"), RVWiringPaths.ruleID, SecretServiceGuard.ruleID,
    ]

    private static let catalog = SecretPathCatalog(
        rules: SecretPathCatalog.dayOne.rules.filter { ruleIDs.contains(SecretPathMatch($0).ruleID) }
    )

    /// File door: the one path's verdict says it.
    static func holds(_ result: EvaluationResult) -> Bool {
        switch result.decision {
        case .indeterminate(.selfProtection), .indeterminate(.observeUnanalyzable):
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
        if holds(result) || SelfProtectionGuard.weakensPolicy(command)
            || SecretServiceGuard.touchesSecretService(command)
        {
            return true
        }
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
        // rv's config is secret: any word naming it holds, read or not.
        if words.contains(where: { rvConfig.filePathHit($0) != nil }) { return true }
        // Wiring files hold no secret, and an observe host already allows
        // these verbs unchecked everywhere else: only a write there holds.
        if ObserveReadProof.proves(command, analysis: result.analysis) { return false }
        return words.contains { namesWiring($0, home: home, cwd: cwd) }
    }

    /// A word naming one of rv's wiring files (`RVWiringPaths`): the shell
    /// door enforces writes there, so an observe host must too. The enforce
    /// branch also runs the judge, so a command proven to only read
    /// (`ObserveReadProof`) is not escalated for naming one.
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
    /// install, in its own text or in program text a shell or interpreter
    /// is fed from a literal pipe, here-string or heredoc (`echo
    /// 'launchctl bootout …' | sh`). Then an allow becomes "run it in
    /// Terminal"; anything else (a deny, an indeterminate) is kept, so the
    /// floor never weakens.
    static func lifecycleFloor(
        _ result: EvaluationResult, command: ShellCommand, home: HomeDirectory?, cwd: WorkingDirectory?
    ) -> EvaluationResult? {
        let texts = [command] + scanOpaqueProgram(command).innerTexts.map { ShellCommand(rawValue: $0) }
        let hits = texts.contains { text in
            RVDStopGuard.stopsRVD(text.rawValue, rvdPIDs: runningRVDaemonPIDs)
                || RVInstallPathGuard.touchesInstall(text, home: home, cwd: cwd)
        }
        guard hits else { return nil }
        return floored(result)
    }

    /// Observe only, after the other floors: a command that runs a program
    /// rv cannot see (`runsUnanalyzable`) is enforced. An allow, or an
    /// "unanalyzable" indeterminate, becomes "run it in Terminal" under
    /// its own rule id; it never becomes a hard deny. Any other verdict (a
    /// deny, a self-protection hold) is kept as is, with its row, rule id,
    /// allow-once path and judge log, like `floored`.
    static func unanalyzableFloor(_ result: EvaluationResult, command: ShellCommand) -> EvaluationResult? {
        guard runsUnanalyzable(result, command: command) else { return nil }
        switch result.decision {
        case .allow:
            break
        case .indeterminate(let reason) where unanalyzableReasons.contains(reason):
            break
        case .deny, .indeterminate:
            return result
        }
        return EvaluationResult(outcome: .indeterminate(.observeUnanalyzable), matchingView: result.matchingView)
    }

    /// The stop and install floors read the command's text, so an encoded
    /// program (`eval "$(echo <b64> | base64 -d)"`, `… | base64 -d | sh`)
    /// passes them, stops rvd, and leaves every later call unchecked. So a
    /// command holds when what rv cannot read can take a command position
    /// (`runsOpaqueProgram`: a dynamic command word, a shell or interpreter
    /// reading stdin that is not from literal producers, a runner whose
    /// verb is a shell or a lifecycle verb), when its program or git
    /// subcommand is unresolved (`invocationIsOpaque`: a dynamic `eval`, a
    /// variable head, a git alias or extension), or when it is too large or
    /// too costly to analyze. A literal verb with dynamic arguments (`xargs
    /// rm`) is not floored here; the lexical floors above read its words,
    /// though not its operands' values. The program checks read the
    /// command again because an earlier pack deny hides them:
    /// `$(echo <b64> | base64 -d)` reports only an out-of-repo write.
    static func runsUnanalyzable(_ result: EvaluationResult, command: ShellCommand) -> Bool {
        if invocationIsOpaque(command) || runsOpaqueProgram(command) { return true }
        if case .indeterminate(let reason) = result.decision { return unanalyzableReasons.contains(reason) }
        return false
    }

    private static let unanalyzableReasons: Set<IndeterminateReason> = [
        .unresolvedInvocation, .budgetExhausted, .commandTooLarge,
    ]

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
