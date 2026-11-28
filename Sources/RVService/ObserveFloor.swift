import Foundation
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
/// stays enforced.
///
/// Observe alone also floors stopping or retuning rvd (`RVDStopGuard`) and writing
/// rv's install (`RVInstallPathGuard`): with rvd absent an observe hook
/// allows every later call unchecked. In enforce a stopped rvd fails
/// closed, so those floors would only add false positives there.
///
/// `rule` is the whole interface: given the door, the verdict and the
/// context, it answers "observed" or "enforce with this result".
/// `GatedEvaluate.posture` is the only caller; on `.enforce` it runs the
/// enforce branch with that result. On a shell door the command's texts
/// are built once under one budget (`ObserveTexts`: the command, program
/// text it feeds a shell or interpreter, and their guard readings), and
/// every detector reads every text.
enum ObserveFloor {
    /// Which door is asking.
    enum Door {
        case file(FileToolAction)
        case shell(ShellCommand, store: PolicyStoreInputs)
    }

    /// Where the command runs, and how to read rvd's running pids
    /// (`runningRVDaemonPIDs` in rvd; tests substitute a table). nil from
    /// `rvdPIDs`: the process table could not be read, so a literal-pid
    /// `kill` fails closed. `provesRead` is `ObserveReadProof.proves`;
    /// tests substitute one that counts its calls. `budget` is the wall
    /// time the shell rule may spend reading the command's texts (rvd must
    /// answer inside the hook's timeout, or the hook allows unchecked);
    /// past it the command fails closed as unanalyzable.
    struct Context {
        let home: HomeDirectory?
        let cwd: WorkingDirectory?
        let rvdPIDs: () -> Set<Int32>?
        let provesRead: (ShellCommand, SemanticAnalysis) -> Bool
        let budget: Duration
        /// The verdict for one segment of a compound command, read on its
        /// own (the gate's pack and semantic evaluation). A pack deny ends
        /// evaluation at its segment, so `git push --force; dd
        /// of=/dev/sda` reports only the push; each segment is read for a
        /// catastrophe too. nil: segments are not read (the file door, and
        /// tests of the rule alone).
        let segmentVerdict: ((ShellCommand) -> EvaluationResult)?

        init(
            home: HomeDirectory?,
            cwd: WorkingDirectory?,
            rvdPIDs: @escaping () -> Set<Int32>? = runningRVDaemonPIDs,
            provesRead: @escaping (ShellCommand, SemanticAnalysis) -> Bool = { ObserveReadProof.proves($0, analysis: $1) },
            budget: Duration = ObserveFloor.lifecycleBudget,
            segmentVerdict: ((ShellCommand) -> EvaluationResult)? = nil
        ) {
            self.home = home
            self.cwd = cwd
            self.rvdPIDs = rvdPIDs
            self.provesRead = provesRead
            self.budget = budget
            self.segmentVerdict = segmentVerdict
        }
    }

    /// Wall time the shell rule may spend reading one command's texts, a
    /// quarter of the hook's 8 s timeout.
    static let lifecycleBudget = Duration.seconds(2)

    enum Ruling: Equatable {
        /// Nothing holds: the door observes the verdict.
        case observed
        /// The door enforces this result: the verdict, or a floor over it.
        /// A floor never weakens: an allow (or an unanalyzable
        /// indeterminate) is raised to "run it in Terminal"; a deny or any
        /// other indeterminate is kept, with its row, rule id, allow-once
        /// path and judge log.
        case enforce(EvaluationResult)
    }

    /// In order, first match wins:
    /// 1. the texts run out of budget: `observe.floor:unanalyzable`, read
    ///    nothing (so does reading them past `Context.budget`, at 2 or 4);
    /// 2. any text stops rvd or writes rv's install: "run it in Terminal";
    /// 3. the verdict is catastrophic (`ObserveCatastrophe`), or it or
    ///    the command as written touches rv's own protection: the
    ///    verdict, enforced; or, for a deny, one segment of the command
    ///    read on its own is catastrophic: that segment's verdict;
    /// 4. any other text (program text the command feeds a shell or
    ///    interpreter, a guard reading) does: "run it in Terminal", since
    ///    the engine never read that text;
    /// 5. the command runs a program rv cannot see:
    ///    `observe.floor:unanalyzable`, over an allow or a watched-class
    ///    deny (`watchedClasses`); any other deny is kept.
    /// The file door reads one path: 2 and 3 only.
    static func rule(_ result: EvaluationResult, door: Door, context: Context) -> Ruling {
        switch door {
        case .file(let action):
            if writesInstall(action, context: context) { return .enforce(floored(result)) }
            return holds(result) ? .enforce(result) : .observed
        case .shell(let command, let store):
            return rule(result, command: command, store: store, context: context)
        }
    }

    private static func rule(
        _ result: EvaluationResult, command: ShellCommand, store: PolicyStoreInputs, context: Context
    ) -> Ruling {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: context.budget)
        let set = observeTexts(command)
        guard set.exhausted == false else { return .enforce(unanalyzable(result)) }
        // The process table is read at most once per command, however many
        // texts hold a literal-pid `kill`.
        let rvdPIDs = readingOnce(context.rvdPIDs)
        for text in set.texts {
            guard clock.now < deadline else { return .enforce(unanalyzable(result)) }
            if stopsOrInstalls(text, rvdPIDs: rvdPIDs, context: context) { return .enforce(floored(result)) }
        }
        var protection = OwnProtection(result: result, command: command, store: store, context: context)
        if holds(result) || ObserveCatastrophe.isCatastrophic(result, command: command.rawValue, home: context.home)
            || protection.touched(by: command.rawValue, matchingView: result.matchingView.rawValue) {
            return .enforce(result)
        }
        // A deny that ended evaluation early may hide a catastrophic later
        // segment, of the command or of program text it feeds a shell
        // (`sh -c 'git reset --hard; rm -rf /usr/*'`): each is read on its
        // own, and the first catastrophic one is enforced under its own rule.
        if case .deny = result.decision, let verdict = context.segmentVerdict {
            for segment in catastropheSegments(command) {
                guard clock.now < deadline else { return .enforce(unanalyzable(result)) }
                let read = verdict(ShellCommand(rawValue: segment))
                if ObserveCatastrophe.isCatastrophic(read, command: segment, home: context.home) {
                    return .enforce(read)
                }
            }
        }
        for text in set.texts where text.origin != .command {
            guard clock.now < deadline else { return .enforce(unanalyzable(result)) }
            if protection.touched(by: text.raw) { return .enforce(floored(result)) }
        }
        if invocationIsOpaque(command) || set.opaque || isUnanalyzable(result) {
            return .enforce(unanalyzable(result))
        }
        return .observed
    }

    /// The commands read on their own for a catastrophe: every simple
    /// command the text launches (`launchedCommands`: chains, pipes,
    /// launchers, and `sh`/`bash`/`zsh -c` or `eval` payloads), rejoined as
    /// shell words, and the outer segments of a compound command as
    /// written; once each, never the whole command again.
    private static func catastropheSegments(_ command: ShellCommand) -> [String] {
        func nonEmpty(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        let launched = launchedCommands(command.rawValue).map(shellText).filter(nonEmpty)
        let outer = shellChainSegments(command.rawValue).filter(nonEmpty)
        var seen: Set<String> = [command.rawValue]
        return (launched + (outer.count > 1 ? outer : [])).filter { seen.insert($0).inserted }
    }

    /// argv as one shell command: a word with blanks, quotes or shell
    /// punctuation is single-quoted; redirect operators, `~`, globs and
    /// expansions stay as they are, so the gate reads them as the shell does.
    private static func shellText(_ argv: [String]) -> String {
        argv.map { word in
            let operatorLike = word.isEmpty == false && word.allSatisfy { "0123456789<>&|".contains($0) }
                && word.contains(where: { "<>".contains($0) })
            guard operatorLike == false, word.isEmpty || word.contains(where: { " \t\n'\";|&()<>`\\".contains($0) }) else {
                return word
            }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: The verdict

    static let ruleIDs: Set<RuleID> = [
        RuleID(pack: .coreSecrets, pattern: "home-rv-config"), RVWiringPaths.ruleID, SecretServiceGuard.ruleID,
    ]

    private static let catalog = SecretPathCatalog(
        rules: SecretPathCatalog.dayOne.rules.filter { ruleIDs.contains(SecretPathMatch($0).ruleID) }
    )

    /// The verdict alone says it (all the file door has).
    private static func holds(_ result: EvaluationResult) -> Bool {
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

    // MARK: rvd and rv's install

    private static func stopsOrInstalls(
        _ text: ObserveTexts.Text, rvdPIDs: @escaping () -> Set<Int32>?, context: Context
    ) -> Bool {
        RVDStopGuard.stopsRVD(text.raw, reading: text.origin == .reading, rvdPIDs: rvdPIDs)
            || RVInstallPathGuard.touchesInstall(ShellCommand(rawValue: text.raw), home: context.home, cwd: context.cwd)
    }

    /// File door: a write or edit of rv's install, typed or resolved.
    private static func writesInstall(_ action: FileToolAction, context: Context) -> Bool {
        guard action.kind != .read else { return false }
        let resolution = SecretPathCandidateResolver.resolution(home: context.home, cwd: context.cwd)
        return RVInstallPathGuard.writesInstall(action.path.rawValue, resolution: resolution, home: context.home)
    }

    // MARK: rv's own protection

    /// Whether a text weakens rv, touches its secret store, or names its
    /// config or wiring. A pack deny is terminal, so `git reset --hard; rv
    /// host mode cursor off` reports only the git rule, and `echo x >
    /// ~/.config/rv/config.json` only a redirect rule; observing that deny
    /// would run the rest too. So every word of a text (raw and with
    /// quotes removed, and for the command its normalized view, split at
    /// shell punctuation) is also checked as an rv-config path, with the
    /// door's exemptions and alias resolution.
    private struct OwnProtection {
        let rvConfig: SecretPathDecider
        let home: HomeDirectory?
        let cwd: WorkingDirectory?
        let command: ShellCommand
        let analysis: SemanticAnalysis
        let provesRead: (ShellCommand, SemanticAnalysis) -> Bool
        /// `ObserveReadProof` of the command, run at most once: it is
        /// O(command), and every text that names a wiring file asks.
        private var provenRead: Bool?

        init(result: EvaluationResult, command: ShellCommand, store: PolicyStoreInputs, context: Context) {
            rvConfig = SecretPathDecider(
                catalog: ObserveFloor.catalog,
                safety: store.safety,
                allowPaths: store.allowPaths.effective,
                home: context.home,
                resolution: SecretPathCandidateResolver.resolution(home: context.home, cwd: context.cwd)
            )
            home = context.home
            cwd = context.cwd
            self.command = command
            analysis = result.analysis
            provesRead = context.provesRead
        }

        mutating func touched(by text: String, matchingView: String? = nil) -> Bool {
            let shell = ShellCommand(rawValue: text)
            if SelfProtectionGuard.weakensPolicy(shell) || SecretServiceGuard.touchesSecretService(shell) {
                return true
            }
            // Also the text with quotes removed, so `"$HOME"/.claude/x`
            // reads as one word.
            let unquoted = text.filter { $0 != "'" && $0 != "\"" }
            let views = [text, unquoted] + (matchingView.map { [$0] } ?? [])
            let words = Set(views.flatMap { view in
                view.split(whereSeparator: { wordBreaks.contains($0) }).map(String.init)
            })
            // rv's config is secret: any word naming it holds, read or not.
            if words.contains(where: { rvConfig.filePathHit($0) != nil }) { return true }
            // Wiring files hold no secret, and an observe host already
            // allows these verbs unchecked everywhere else: only a write
            // there holds. A command proven to only read (`ObserveReadProof`)
            // feeds no shell or interpreter, so the proof covers its texts.
            // A delete, move or mode change of a directory above a wiring
            // file (`rm -rf ~/.claude`) unhooks rv for that host as surely
            // as editing the file inside (`RVWiringPaths.matchesAncestor`).
            let namesWiringFile = words.contains(where: { namesWiring($0) })
            let unhooksAncestor = namesWiringFile == false
                && words.contains(where: { Self.unhookingVerbs.contains($0) })
                && words.contains(where: { namesWiringAncestor($0) })
            guard namesWiringFile || unhooksAncestor else { return false }
            return provesCommandOnlyReads() == false
        }

        /// Verbs that delete, move or re-mode what they name.
        private static let unhookingVerbs: Set<String> = [
            "rm", "rmdir", "mv", "unlink", "shred", "srm", "trash", "chmod", "chown", "chflags", "-delete",
        ]

        private func namesWiringAncestor(_ word: String) -> Bool {
            guard let home else { return false }
            let path = lexicalFilesystemPath(word, workingDirectory: cwd, homeDirectory: home)
            return RVWiringPaths.matchesAncestor(path, home: home.rawValue)
        }

        private mutating func provesCommandOnlyReads() -> Bool {
            if let provenRead { return provenRead }
            let proven = provesRead(command, analysis)
            provenRead = proven
            return proven
        }

        /// A word naming one of rv's wiring files (`RVWiringPaths`): the
        /// shell door enforces writes there, so an observe host must too.
        /// The enforce branch also runs the judge, so a command proven to
        /// only read is not escalated for naming one. The word is
        /// normalised first (`~`/`$HOME`/`~user` expanded, joined to the
        /// cwd, `.`/`..` collapsed). Host settings files at any scope
        /// count: a project one can disable hooks for every host.
        private func namesWiring(_ word: String) -> Bool {
            if RVWiringPaths.isHostSettingsFile(word) { return true }
            guard let home else { return false }
            let path = lexicalFilesystemPath(word, workingDirectory: cwd, homeDirectory: home)
            return RVWiringPaths.matches(path, home: home.rawValue)
        }
    }

    // MARK: Programs rv cannot see

    /// The stop and install floors read the command's texts, so an encoded
    /// program (`eval "$(echo <b64> | base64 -d)"`, `… | base64 -d | sh`)
    /// passes them, stops rvd, and leaves every later call unchecked. So a
    /// command holds when what rv cannot read can take a command position
    /// (`ObserveTexts.opaque`: a dynamic command word, a shell or
    /// interpreter reading stdin that is not from literal producers, a
    /// runner whose verb is a shell or a lifecycle verb), when its program
    /// or git subcommand is unresolved (`invocationIsOpaque`: a dynamic
    /// `eval`, a variable head, a git alias or extension), or when it is
    /// too large or too costly to analyze. A literal verb with dynamic
    /// arguments (`xargs rm`) is not floored here; the lexical floors read
    /// its words, though not its operands' values. The program checks read
    /// the command, not the verdict, because an earlier pack deny hides
    /// them: `$(echo <b64> | base64 -d)` reports only an out-of-repo write.
    private static func isUnanalyzable(_ result: EvaluationResult) -> Bool {
        if case .indeterminate(let reason) = result.decision { return unanalyzableReasons.contains(reason) }
        return false
    }

    private static let unanalyzableReasons: Set<IndeterminateReason> = [
        .unresolvedInvocation, .budgetExhausted, .commandTooLarge,
    ]

    /// An allow, an "unanalyzable" indeterminate, or a watched-class deny
    /// (`watchedClasses`) becomes "run it in Terminal" under its own rule
    /// id; it never becomes a hard deny. Any other deny is kept.
    ///
    /// A watched-class deny is no reason to stop in observe (Q5: only
    /// catastrophic commands and rv's own protection stop there); the
    /// command stops only because rv cannot see what it runs, so the stop
    /// carries that reason. Never weaker: like the pinned deny it replaces,
    /// the indeterminate takes no allow-once, ask or allowlist entry.
    private static func unanalyzable(_ result: EvaluationResult) -> EvaluationResult {
        switch result.decision {
        case .allow:
            break
        case .indeterminate(let reason) where unanalyzableReasons.contains(reason):
            break
        case .deny(let deny) where isWatchedClass(deny.ruleID):
            break
        case .deny, .indeterminate:
            return result
        }
        return EvaluationResult(outcome: .indeterminate(.observeUnanalyzable), matchingView: result.matchingView)
    }

    /// Built-in denies that observe watches (logs as a would-be stop and
    /// lets run) instead of stopping: an unresolved path, a write outside
    /// the repository, and wrapper or interpreter nesting past the unwrap
    /// limit. Enforce still stops each. Observe stops one of them only when
    /// it is also catastrophic or touches rv's own protection (rules 2 to
    /// 4 keep the deny then) or rv cannot see what it runs (rule 5, as
    /// `observe.floor:unanalyzable`).
    static let watchedClasses: Set<BuiltinRule> = [.unresolvedPath, .outOfRepoWrite, .unwrapLimited]

    static func isWatchedClass(_ ruleID: RuleID) -> Bool {
        BuiltinRule(ruleID).map { watchedClasses.contains($0) } ?? false
    }

    /// An allow becomes "run it in Terminal"; anything else is kept.
    private static func floored(_ result: EvaluationResult) -> EvaluationResult {
        guard result.decision == .allow else { return result }
        return EvaluationResult(outcome: .indeterminate(.selfProtection), matchingView: result.matchingView)
    }

    private static let wordBreaks: Set<Character> = [
        " ", "\t", "\n", "\r", ";", "|", "&", "(", ")", "<", ">", "'", "\"", "`", "=", ",",
    ]
}
