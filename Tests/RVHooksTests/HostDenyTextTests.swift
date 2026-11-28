import Testing
import RVDomain
@testable import RVHooks

private let resetHard = ShellCommand(rawValue: "git reset --hard")
private let resetHardRule = RuleID(pack: .coreGit, pattern: "reset-hard")
private let resetHardDeny = Deny(
    ruleID: resetHardRule,
    reason: "git reset --hard destroys uncommitted changes. Use 'git stash' first."
)

/// `git reset --hard` stopped with no code, no name and no pack advice
/// (`StopVoice.plain`).
let resetHardHostDeny = """
    ✕ Stopped   git reset --hard (core.git/reset-hard)
    why     destroys uncommitted changes
    who     ask your user to run it in their own terminal
    """

/// The B1 shape every stop text keeps: the verdict with the rule id, why,
/// at most one safer command, and one `who`. Plain text (no ANSI, no box
/// drawing), and never an unlock the agent runs itself.
func assertHookDenyHasNoBypassOrEssay(_ text: String?) {
    let payload = text ?? ""
    #expect(payload.contains("✕ Stopped   "))
    #expect(payload.contains("RV · Blocked") == false)
    #expect(payload.contains("reset --soft") == false)
    #expect(payload.contains("RV_" + "BYPASS") == false)
    #expect(payload.contains("\u{001B}") == false)
    #expect(payload.contains("═") == false)
    #expect(payload.contains("┌") == false)
    #expect(payload.contains("Paste in Terminal") == false)
    #expect(payload.contains("open RV") == false)
    // The only allow-once in a stop is the owner's, on the who line.
    for line in payload.split(separator: "\n") where line.contains("allow-once") {
        #expect(line.hasPrefix("who     ask "), "allow-once outside the who line: \(line)")
    }
}

func mintedUnlock(_ raw: String = "a1b2c3") throws -> AllowOnceUnlockCode {
    try #require(AllowOnceUnlockCode(validating: raw))
}

func mintedResetHardHostDeny(_ code: AllowOnceUnlockCode) -> String {
    """
    ✕ Stopped   git reset --hard (core.git/reset-hard)
    why     destroys uncommitted changes
    who     ask your user to run  rv allow-once \(code.rawValue)
    """
}

func assertMintedHookUnlock(_ text: String, why: String = resetHardHostDeny) throws -> AllowOnceUnlockCode {
    let minted = try #require(allowOnceUnlockCode(in: text))
    #expect(text.contains(unlockLine(for: minted)))
    #expect(text.hasPrefix("✕ Stopped   "))
    assertHookDenyHasNoBypassOrEssay(text)
    let whyLine = why.split(separator: "\n").first { $0.hasPrefix("why ") }
    if let whyLine {
        #expect(text.contains(whyLine))
    }
    return minted
}

private func words(_ text: String) -> Int {
    text.split(separator: " ").count
}

// MARK: - Shape

@Test func stopNotice_rendersTheNorthStarShape() {
    let notice = StopNotice(
        subject: "git reset --hard origin/main",
        rule: "core.git/reset-hard",
        why: "destroys uncommitted changes",
        safer: "git status",
        who: "ask Chris to run  rv allow-once a1b2c3"
    )
    #expect(notice.text == """
        ✕ Stopped   git reset --hard origin/main (core.git/reset-hard)
        why     destroys uncommitted changes
        safer   git status
        who     ask Chris to run  rv allow-once a1b2c3
        """)
    var bare = notice
    bare.subject = nil
    bare.safer = nil
    #expect(bare.text.hasPrefix("✕ Stopped   (core.git/reset-hard)\nwhy     "))
    #expect(bare.text.contains("safer") == false)
}

@Test func hostDenyText_nilOnAllowIncludingMedium() {
    let allow = EvaluationResult(outcome: .plain)
    #expect(hostDenyText(from: allow, command: ShellCommand(rawValue: "git status")) == nil)

    let rule = RuleID(pack: .coreGit, pattern: "stash-drop")
    let medium = EvaluationResult(
        outcome: .hit(
            RuleMatch(
                ruleID: rule,
                severity: .medium,
                reason: "git stash drop deletes a single stash"
            ),
            safe: nil
        )
    )
    #expect(hostDenyText(from: medium, command: ShellCommand(rawValue: "git stash drop")) == nil)
}

@Test func hostDenyText_denyIsTheShape() {
    let result = EvaluationResult(outcome: .deny(resetHardDeny, matched: nil))
    let text = hostDenyText(from: result, command: resetHard)
    #expect(text == resetHardHostDeny)
    #expect(text?.contains("ALLOW-") == false)
    #expect(text?.contains("redeem") == false)
    assertHookDenyHasNoBypassOrEssay(text)
}

@Test func hostDenyText_namesOwnerAndPackAdvice() throws {
    let voice = StopVoice(owner: OwnerName(gecos: "Christopher Karani,,,")) { rule in
        rule == resetHardRule ? StopAdvice(saferCommand: "git status") : nil
    }
    let code = try mintedUnlock()
    let minted = hostDenyLine(
        command: ShellCommand(rawValue: "git reset --hard origin/main"),
        deny: resetHardDeny, kind: .ask(recorded: true), unlock: .code(code), voice: voice)
    #expect(minted == """
        ✕ Stopped   git reset --hard origin/main (core.git/reset-hard)
        why     destroys uncommitted changes
        safer   git status
        who     ask Christopher to run  rv allow-once a1b2c3
        """)
    let earlier = hostDenyLine(command: resetHard, deny: resetHardDeny, unlock: .earlierPending, voice: voice)
    #expect(earlier.hasSuffix("who     ask Christopher to run the earlier code with  rv allow-once"))
    assertHookDenyHasNoBypassOrEssay(minted)
    assertHookDenyHasNoBypassOrEssay(earlier)
}

/// A pinned deny (no code) says who acts as the pack wrote it, turned
/// toward the owner: the agent never reads "you, in your own terminal" as
/// its own step.
@Test func hostDenyText_whoActsSpeaksForTheOwner() {
    let push = Deny(ruleID: RuleID(pack: .coreGit, pattern: "push-force-long"), reason: "Force push can destroy remote history.")
    let voice = StopVoice(owner: OwnerName(gecos: "Chris")) { _ in
        StopAdvice(whoActs: "you, in your own terminal, after checking no one else pushed")
    }
    let text = hostDenyLine(command: ShellCommand(rawValue: "git push --force"), deny: push, voice: voice)
    #expect(text == """
        ✕ Stopped   git push --force (core.git/push-force-long)
        why     force push can destroy remote history
        who     ask Chris to run it, in their own terminal, after checking no one else pushed
        """)
    #expect(whoActsLine("no one: there is no safe form", owner: .unknown) == "no one: there is no safe form")
    #expect(whoActsLine("you", owner: .unknown) == "ask your user to run it")
}

/// A minted code wins over the pack's who: one step, never two.
@Test func hostDenyText_oneWhoEvenWithAdvice() throws {
    let voice = StopVoice(owner: .unknown) { _ in StopAdvice(saferCommand: "git status", whoActs: "you, in your own terminal") }
    let text = hostDenyLine(command: resetHard, deny: resetHardDeny, unlock: .code(try mintedUnlock()), voice: voice)
    #expect(text.components(separatedBy: "\nwho     ").count == 2)
    #expect(text.contains("in their own terminal") == false)
    #expect(text.components(separatedBy: "\nsafer   ").count == 2)
}

#if os(macOS)
@Test func hostDenyText_askWithoutCodeNamesTheRVApp() {
    let staged = hostDenyLine(command: resetHard, deny: resetHardDeny, kind: .ask(recorded: true))
    #expect(staged.hasSuffix("who     ask your user to approve it in RV"))
    let unrecorded = hostDenyLine(command: resetHard, deny: resetHardDeny, kind: .ask(recorded: false))
    #expect(unrecorded.hasSuffix("who     ask your user to run it in their own terminal"))
}
#endif

/// A safer command that reaches for an unlock is never printed.
@Test func hostDenyText_dropsSaferThatUnlocks() {
    let voice = StopVoice(owner: .unknown) { _ in StopAdvice(saferCommand: "rv allow-once abcdef") }
    let text = hostDenyLine(command: resetHard, deny: resetHardDeny, voice: voice)
    #expect(text.contains("safer") == false)
}

// MARK: - Why

@Test func stopWhy_isUnderTenWordsAndDropsTheCommand() {
    #expect(stopWhy("git reset --hard destroys uncommitted changes. Use 'git stash' first.", command: resetHard)
        == "destroys uncommitted changes")
    #expect(stopWhy("A. B. C. D.", command: ShellCommand(rawValue: "echo")) == "a")
    #expect(
        stopWhy("rm -rf on root or home paths is EXTREMELY DANGEROUS. This command will NOT be executed.",
                command: ShellCommand(rawValue: "rm -rf /"))
            == "rm -rf on root or home paths is catastrophic")
    #expect(
        stopWhy("rm -rf is destructive and requires human approval. Explain what you want.",
                command: ShellCommand(rawValue: "rm -rf build"))
            == "it is destructive")
    let long = stopWhy(
        "one two three four five six seven eight nine ten eleven", command: nil)
    #expect(long == "one two three four five six seven eight nine…")
    #expect(words(long) == stopWhyWordLimit)
    #expect(stopWhy("RESET MASTER deletes all binary logs.", command: nil) == "RESET MASTER deletes all binary logs")
    // A leading environment assignment is not the program the reason names.
    #expect(stopWhy("git reset --hard destroys uncommitted changes.",
                    command: ShellCommand(rawValue: "GIT_DIR=.git LANG=C git reset --hard"))
        == "destroys uncommitted changes")
    // One shared word is a different command: the reason keeps its subject.
    #expect(stopWhy("git reset --hard destroys uncommitted changes.",
                    command: ShellCommand(rawValue: "git clone https://example.com/a.git"))
        == "git reset --hard destroys uncommitted changes")
}

@Test func stopWhy_neverRepeatsAWayPast() {
    for reason in [
        "Run rv allow-once next.", "Unlock it first.", "Then redeem it.", "Env RV_BYPASS skips it.",
        "Use the bypass.",
    ] {
        #expect(stopWhy(reason, command: nil) == genericStopWhy, Comment(rawValue: reason))
    }
    #expect(stopWhy("", command: nil) == genericStopWhy)
    #expect(stopWhy("   ", command: nil) == genericStopWhy)
}

@Test func stopWhy_isOneEscapedLine() {
    let why = stopWhy("bad\nline \u{1B}[31mred\u{202E}", command: nil)
    #expect(why.contains("\n") == false)
    #expect(why.contains("\u{1B}") == false)
    #expect(why.contains("\u{202E}") == false)
}

// MARK: - Indeterminate and hook-call stops

@Test func hostDenyText_indeterminateNamesItsReason() {
    let reasons: [IndeterminateReason] = [
        .budgetExhausted, .commandTooLarge, .corePacksUnavailable, .inlineProgramNeedsJudge,
        .selfProtection, .packageScriptUnresolved, .unresolvedInvocation,
    ]
    for reason in reasons {
        let text = hostDenyText(from: EvaluationResult(outcome: .indeterminate(reason)), command: resetHard)
        let lines = text?.split(separator: "\n").map(String.init) ?? []
        #expect(lines.count == 3)
        #expect(lines.first == "✕ Stopped   git reset --hard (rv.indeterminate/\(reason.rawValue))")
        #expect(lines.dropFirst().first == "why     \(indeterminateStopWhy(reason))")
        #expect(lines.last == "who     ask your user to run it in their own terminal")
        #expect(text?.contains("core.git") == false)
        #expect(words(indeterminateStopWhy(reason)) <= stopWhyWordLimit)
    }
}

/// The observe floor's stop says why: rv could not see what the command
/// runs, under its own rule id. It never names self-protection.
@Test func hostDenyText_observeUnanalyzableSaysWhy() {
    let result = EvaluationResult(outcome: .indeterminate(.observeUnanalyzable))
    let command = ShellCommand(rawValue: "git st")
    let want = """
        ✕ Stopped   git st (observe.floor/unanalyzable)
        why     rv could not see what this command runs
        who     ask your user to run it in their own terminal
        """
    #expect(hostDenyText(from: result, command: command) == want)
    #expect(denyPresentation(from: result, command: command, unlockCode: nil).reason == want)
    #expect(IndeterminateReason.observeUnanalyzable.rawValue == "observe.floor:unanalyzable")
}

@Test func hookCallStops_nameTheirRule() {
    let doctor = "ask your user to run  rv doctor"
    #expect(malformedHookSentence(.unreadable) == """
        ✕ Stopped   (rv.hook/unreadable)
        why     rv could not read this hook request
        who     \(doctor)
        """)
    #expect(malformedHookSentence(.missingCommand) == """
        ✕ Stopped   (rv.hook/no-command)
        why     the shell hook carried no command
        who     \(doctor)
        """)
    #expect(hookCallStopNotice(.timedOut).text.hasPrefix("✕ Stopped   (rv.timeout)\n"))
}

@Test func hostDenyText_switchesOnDecisionNotNilHeuristic() {
    let deny = EvaluationResult(outcome: .deny(Deny(ruleID: resetHardRule, reason: "x"), matched: nil))
    let allow = EvaluationResult(outcome: .plain)
    #expect(hostDenyText(from: deny, command: resetHard) != nil)
    #expect(hostDenyText(from: allow, command: resetHard) == nil)
    #expect(deny.decision != allow.decision)
}

// MARK: - Subjects

@Test func hostDenyText_multilineCommand_previewsFirstLine() {
    let command = ShellCommand(
        rawValue: """
        cat >> /Users/chriskarani/.grok/skill-observations/log.md << 'EOF'
        ### Observation 760: placeholder
        See `origin/<base>...HEAD`
        EOF
        """
    )
    let rule = RuleID(pack: .coreFilesystem, pattern: "redirect-truncate-dynamic-path")
    let result = EvaluationResult(outcome: .deny(Deny(ruleID: rule, reason: "dynamic"), matched: nil))
    let text = hostDenyText(from: result, command: command)
    let preview = hookDenyCommandPreview(command)
    #expect(preview.hasSuffix("…"))
    #expect(preview.contains("cat >>"))
    #expect(preview.contains("Observation 760") == false)
    #expect(text?.hasPrefix("✕ Stopped   \(preview) (core.filesystem/redirect-truncate-dynamic-path)\n") == true)
    #expect(text?.contains("Observation 760") == false)
    #expect(text?.contains("<base>") == false)
    #expect(text?.split(separator: "\n").count == 3)
}

@Test func hookDenyCommandPreview_escapesControls() {
    let preview = hookDenyCommandPreview(ShellCommand(rawValue: "echo \u{1B}[2J\u{202E}x"))
    #expect(preview.contains("\u{1B}") == false)
    #expect(preview.contains("\u{202E}") == false)
}

@Test func hookDenyCommandPreview_shortCommandUnchanged() {
    #expect(hookDenyCommandPreview(resetHard) == "git reset --hard")
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: "git reset --hard\n")) == "git reset --hard")
}

@Test func hookDenyCommandPreview_clipsOverlongFirstLine() {
    let exact = String(repeating: "a", count: hookDenyCommandPreviewLimit)
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: exact)) == exact)
    let raw = String(repeating: "a", count: hookDenyCommandPreviewLimit + 8)
    let preview = hookDenyCommandPreview(ShellCommand(rawValue: raw))
    #expect(preview == exact + "…")
    #expect(preview.contains("\n") == false)
}

@Test func hostFileDenyLine_showsThePath() {
    let deny = Deny(ruleID: RuleID(pack: .coreSecrets, pattern: "ssh-key"), reason: "Access to a sensitive path is not allowed.")
    #expect(hostFileDenyLine(path: FileToolPath(rawValue: "~/.ssh/id_rsa"), deny: deny) == """
        ✕ Stopped   ~/.ssh/id_rsa (core.secrets/ssh-key)
        why     access to a sensitive path is not allowed
        who     ask your user to run it in their own terminal
        """)
    #expect(hostFileDenyLine(deny: deny).hasPrefix("✕ Stopped   (core.secrets/ssh-key)\n"))
}

// MARK: - Unlock lines

@Test func unlockLine_isTheOwnersStep() throws {
    #expect(AllowOnceUnlockCode(validating: "abc") == nil)
    #expect(AllowOnceUnlockCode(validating: "ABCDEF") == nil)
    let code = try mintedUnlock()
    #expect(unlockLine(for: code) == "ask your user to run  rv allow-once a1b2c3")
    #expect(unlockLine(for: code, owner: OwnerName(gecos: "Chris")) == "ask Chris to run  rv allow-once a1b2c3")
    #expect(allowOnceUnlockCode(in: ownTerminalLine()) == nil)
    #expect(allowOnceUnlockCode(in: unlockLine(for: code)) == code)
}

@Test func allowOnceUnlockCode_isSixLowercaseHex() {
    #expect(AllowOnceUnlockCode(validating: "abc") == nil)
    #expect(AllowOnceUnlockCode(validating: "abcde") == nil)
    #expect(AllowOnceUnlockCode(validating: "ABCDEF") == nil)
    #expect(AllowOnceUnlockCode(validating: "a1b2c3")?.rawValue == "a1b2c3")
    #expect(AllowOnceUnlockCode(validating: "000000")?.rawValue == "000000")
    #expect(AllowOnceUnlockCode.isValid("a1b2c3"))
    #expect(AllowOnceUnlockCode.isValid("abcde") == false)
}

@Test func hookVoiceNext_sentencesAreWhoLines() throws {
    #expect(hookVoiceNextSentence(.none) == nil)
    #expect(hookVoiceNextSentence(.ttyHint) == ownTerminalLine())
    let code = try mintedUnlock()
    #expect(hookVoiceNextSentence(.minted(code)) == unlockLine(for: code))
    #expect(unlockHookVoiceNext(Optional<AllowOnceUnlockMint>.none) == .none)
    #expect(unlockHookVoiceNext(nil as AllowOnceUnlockMint?, fallback: .ttyHint) == .ttyHint)
    #expect(unlockHookVoiceNext(.code(code)) == .minted(code))
    #expect(hookVoiceNextSentence(.earlierPending) == earlierPendingUnlockLine())
    #expect(unlockHookVoiceNext(.earlierPending) == .earlierPending)
}

@Test func hostDenyLine_putsTheCodeOnTheWhoLine() throws {
    let code = try mintedUnlock()
    #expect(hostDenyLine(command: resetHard, deny: resetHardDeny) == resetHardHostDeny)
    let minted = hostDenyLine(command: resetHard, deny: resetHardDeny, unlock: .code(code))
    #expect(minted == mintedResetHardHostDeny(code))
    _ = try assertMintedHookUnlock(minted)
}

/// A deny whose reason hands the owner one rv repair command keeps it as
/// the stop's single step; a reason naming any other command does not.
@Test func reasonNamedRepairCommandBecomesTheWho() {
    let judge = Deny(
        ruleID: RuleID(pack: PackID(rawValue: "rv.judge"), pattern: "unavailable"),
        reason: "Laya judge pool could not load the model (bad bundle); judged calls go to review. Ask the owner to run `rv doctor`."
    )
    let notice = stopNotice(command: ShellCommand(rawValue: "python3 -c 'x'"), deny: judge)
    #expect(notice.who == ownerRunsLine("rv doctor"))
    #expect(notice.text.split(separator: "\n").count == 3)

    let restart = Deny(ruleID: judge.ruleID, reason: "rvd is stale. Run `rv service restart`.")
    #expect(stopNotice(command: ShellCommand(rawValue: "x"), deny: restart).who == ownerRunsLine("rv service restart"))

    for named in ["`rv allow-once a1b2c3`", "`rv unlock a1b2c3`", "`rm -rf /`", "rv doctor"] {
        let other = Deny(ruleID: judge.ruleID, reason: "Blocked. Run \(named).")
        #expect(stopNotice(command: ShellCommand(rawValue: "x"), deny: other).who == ownTerminalLine(), "\(named)")
    }
}

/// Fake credentials in the shapes an agent's command carries them. None is
/// a real key; each has the length and characters the redactor keys on.
enum StopSecretProbe {
    static let githubToken = "ghp_" + String(repeating: "A1b2", count: 9)
    static let anthropicKey = "sk-ant-api03-" + String(repeating: "Zz9_", count: 8)
    static let commands: [String] = [
        "git clone https://bob:hunter2pass@github.com/acme/app.git",
        "GITHUB_TOKEN=\(githubToken) git reset --hard",
        "curl -H 'Authorization: Bearer \(githubToken)' https://api.github.com/user",
        "rm -rf ~ # \(anthropicKey)",
    ]
    static let secrets = ["hunter2pass", githubToken, anthropicKey]
}

/// The verdict line reaches the host's transcript and the agent: a
/// credential in the command is hidden before it is echoed, on every
/// stop that shows the command.
@Test(arguments: StopSecretProbe.commands)
func stopVerdictLine_hidesCredentials(_ raw: String) {
    let command = ShellCommand(rawValue: raw)
    let preview = hookDenyCommandPreview(command)
    let rule = RuleID(pack: .coreGit, pattern: "reset-hard")
    let notices = [
        stopNotice(command: command, deny: Deny(ruleID: rule, reason: "x destroys things."), voice: .plain),
        indeterminateStopNotice(.unresolvedInvocation, command: command, voice: .plain),
    ]
    for secret in StopSecretProbe.secrets {
        #expect(preview.contains(secret) == false, "\(raw)")
        for notice in notices {
            #expect(notice.text.contains(secret) == false, "\(raw)")
        }
    }
    #expect(preview.contains(CommandLineRedaction.placeholder), "\(raw)")
}

/// `\r\n` is one Character: the first line still ends there.
@Test func hookDenyCommandPreview_endsTheLineAtCRLF() {
    let preview = hookDenyCommandPreview(ShellCommand(rawValue: "git reset --hard\r\necho second"))
    #expect(preview == "git reset --hard…")
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: "git reset --hard\r\n")) == "git reset --hard")
    #expect(hookDenyCommandPreview(ShellCommand(rawValue: "a\u{2028}b")) == "a…")
}
