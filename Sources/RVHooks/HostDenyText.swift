import RVDomain

// MARK: - One shape for every stop (North Star B1)
//
// Every stop rv sends a host reads the same way, on every codec:
//
//     ✕ Stopped   git reset --hard (core.git/reset-hard)
//     why     destroys uncommitted changes
//     safer   git status
//     who     ask Chris to run  rv unlock a1b2c3
//
// The verdict and the command, the rule id, why in under ten words, one
// safer command when the rule's pack offers one, and who acts. The text is
// plain (it goes to an agent, not a TTY): no ANSI, no box drawing. It never
// tells the agent to run `rv unlock` itself: the code is for the person
// the `who` line names. "Cost in numbers" (B3) and self-protection's own
// words (B2) come later.

/// What a rule's pack offers the agent it stops (`safer_command`,
/// `who_acts` in pack JSON, G1). RVHooks never loads packs; the hook door's
/// owner passes a lookup in `StopVoice`.
public struct StopAdvice: Sendable, Equatable {
    /// A command to run instead, copy-ready, that rv allows in the same mode.
    public var saferCommand: String?
    /// Who has to act when there is no unlock code, as the pack says it
    /// ("you, in your own terminal, after checking no one else pushed").
    public var whoActs: String?

    public init(saferCommand: String? = nil, whoActs: String? = nil) {
        self.saferCommand = saferCommand
        self.whoActs = whoActs
    }
}

/// Who a stop asks to act, and the advice each rule carries.
public struct StopVoice: Sendable {
    /// The machine owner's first name ("ask Chris"), from passwd.
    public var owner: OwnerName
    /// The pack advice for a rule id, else rv's own (`builtinStopAdvice`),
    /// or nil.
    public var advice: @Sendable (RuleID) -> StopAdvice?
    /// How many stops of this rule the session has hit lately, this one
    /// included (B5); 0 when nothing counted.
    public var streak: Int
    /// Whether a self-protection stop offers its help page: false once the
    /// hook door found rv would not let that page run here (`vetted`).
    public var offersSelfProtectionHelp = true

    public init(
        owner: OwnerName, advice: @escaping @Sendable (RuleID) -> StopAdvice? = { _ in nil }, streak: Int = 0
    ) {
        self.owner = owner
        self.advice = { rule in advice(rule) ?? builtinStopAdvice(rule) }
        self.streak = streak
    }

    /// No name ("your user") and no pack advice.
    public static let plain = StopVoice(owner: .unknown)

    /// This voice, with `rule`'s safer command left out (its `who_acts`
    /// stays): for a stop whose pack advice rv would itself stop.
    public func withoutSaferCommand(for rule: RuleID) -> StopVoice {
        let advice = self.advice
        var voice = self
        voice.advice = { asked in
            guard var found = advice(asked) else { return nil }
            if asked == rule { found.saferCommand = nil }
            return found
        }
        return voice
    }

    /// This voice for `result`'s stop of `command` at `cwd`: the safer
    /// command it would show (the stopping rule's advice, pack or rv's own,
    /// or a self-protection stop's help page) stays only when `allowed`
    /// says rv lets it run there.
    public func vetted(
        for result: EvaluationResult,
        command: ShellCommand? = nil,
        cwd: WorkingDirectory?,
        by allowed: (@Sendable (ShellCommand, WorkingDirectory?) async -> Bool)?
    ) async -> StopVoice {
        guard let allowed else { return self }
        switch result.decision {
        case .deny(let deny):
            guard let safer = advice(deny.ruleID)?.saferCommand else { return self }
            return await allowed(ShellCommand(rawValue: safer), cwd) ? self : withoutSaferCommand(for: deny.ruleID)
        case .indeterminate(.selfProtection):
            guard let help = command.flatMap(selfProtectionSaferCommand) else { return self }
            var voice = self
            voice.offersSelfProtectionHelp = await allowed(ShellCommand(rawValue: help), cwd)
            return voice
        default:
            return self
        }
    }
}

/// One stop, in the shape every host shows.
public struct StopNotice: Sendable, Equatable {
    /// The verdict word after the glyph: `Stopped`, or self-protection's
    /// own `rv protects itself` (B2).
    public var verdict: String
    /// The command (first line, escaped) or path; nil for a stop that has
    /// no command (an unreadable hook request).
    public var subject: String?
    /// The rule id in slash display (`core.git/reset-hard`).
    public var rule: String
    /// Why, in under ten words.
    public var why: String
    /// One safer command, or nil.
    public var safer: String?
    /// Who acts ("ask Chris to run  rv allow-once a1b2c3").
    public var who: String
    /// The third-try note (B5, `stopStreakNote`), or nil.
    public var again: String?

    public init(
        verdict: String = CommandVocabulary.Glyph.stopped.word,
        subject: String?, rule: String, why: String, safer: String? = nil, who: String, again: String? = nil
    ) {
        self.verdict = verdict
        self.subject = subject
        self.rule = rule
        self.why = why
        self.safer = safer
        self.who = who
        self.again = again
    }

    /// The host text: one idea per line, the next command last.
    public var text: String {
        var lines = [verdictLine]
        lines.append(stopLabel("why") + why)
        if let safer {
            lines.append(stopLabel("safer") + safer)
        }
        if let again {
            lines.append(stopLabel("again") + again)
        }
        lines.append(stopLabel("who") + who)
        return lines.joined(separator: "\n")
    }

    /// `✕ Stopped   <command> (<rule>)`.
    public var verdictLine: String {
        let head = "\(CommandVocabulary.Glyph.stopped.rawValue) \(verdict)   "
        guard let subject, subject.isEmpty == false else {
            return "\(head)(\(rule))"
        }
        return "\(head)\(subject) (\(rule))"
    }
}

/// Label column of a stop: `why     `, `safer   `, `who     ` (8 wide, as
/// the North Star anatomy frame sets it).
func stopLabel(_ label: String) -> String {
    label + String(repeating: " ", count: max(1, stopLabelWidth - label.count))
}

let stopLabelWidth = 8

/// The gap the North Star frames leave before a command to copy.
let commandGap = "  "

// MARK: - Unlock next steps

/// Six lowercase hex characters minted for TTY redeem.
public func isAllowOnceUnlockCode(_ code: String) -> Bool {
    AllowOnceUnlockCode.isValid(code)
}

/// Next-step on host deny/ask JSON. Prefer `.none` over `HookVoiceNext?`.
public enum HookVoiceNext: Sendable, Equatable {
    case none
    case ttyHint
    case minted(AllowOnceUnlockCode)
    case earlierPending
}

/// The `who` line for a minted code: the owner runs it, never the agent.
/// The grant binds the normalized command (sudo/env/path spellings share
/// one grant, B-F2).
/// The aside after it is the agent's, and says so: `rv wait <code>` (H2)
/// only waits for the owner's answer and never decides anything.
public func unlockLine(for code: AllowOnceUnlockCode, owner: OwnerName = .unknown) -> String {
    "\(askOwner(owner)) to run\(commandGap)\(CommandVocabulary.Alias.unlock.invocation) \(code.rawValue)"
        + "\(commandGap)(you can wait: \(CommandVocabulary.Command.wait.invocation) \(code.rawValue))"
}

/// The `who` line for a repeat stop of the same command and cwd: no second
/// code is minted.
public func earlierPendingUnlockLine(owner: OwnerName = .unknown) -> String {
    "\(askOwner(owner)) to run the earlier code with\(commandGap)\(CommandVocabulary.Alias.unlock.invocation)"
}

/// The `who` line when rv minted nothing and the pack names no one: the
/// owner runs it themselves.
public func ownTerminalLine(owner: OwnerName = .unknown) -> String {
    "\(askOwner(owner)) to run it in their own terminal"
}

/// The `who` line for an ask staged in the RV app (macOS) with no code.
public func approveInRVLine(owner: OwnerName = .unknown) -> String {
    "\(askOwner(owner)) to approve it in RV"
}

/// The `who` line for a stop the owner fixes with one rv command
/// (`rv doctor`, `rv service restart`).
public func ownerRunsLine(_ command: String, owner: OwnerName = .unknown) -> String {
    "\(askOwner(owner)) to run\(commandGap)\(command)"
}

private func askOwner(_ owner: OwnerName) -> String {
    "ask \(owner.spoken)"
}

/// Pack `who_acts` for the agent: the pack writes it to the person ("you,
/// in your own terminal"), so the agent reads it as the owner's step ("ask
/// Chris to run it, in their own terminal"). Text that does not start with
/// "you" ("no one: there is no safe form") is kept as written.
func whoActsLine(_ whoActs: String, owner: OwnerName) -> String {
    let text = singleLine(whoActs)
    let lower = text.lowercased()
    guard lower == "you" || lower.hasPrefix("you,") || lower.hasPrefix("you ") else {
        return text
    }
    let rest = String(text.dropFirst(3)).replacingOccurrences(of: "your own", with: "their own")
    return "\(askOwner(owner)) to run it\(rest)"
}

func hookVoiceNextSentence(_ next: HookVoiceNext, owner: OwnerName = .unknown) -> String? {
    switch next {
    case .none:
        return nil
    case .ttyHint:
        return ownTerminalLine(owner: owner)
    case .minted(let code):
        return unlockLine(for: code, owner: owner)
    case .earlierPending:
        return earlierPendingUnlockLine(owner: owner)
    }
}

func unlockHookVoiceNext(_ mint: AllowOnceUnlockMint?, fallback: HookVoiceNext = .none) -> HookVoiceNext {
    switch mint {
    case .code(let code):
        return .minted(code)
    case .earlierPending:
        return .earlierPending
    case nil:
        return fallback
    }
}

/// First `rv unlock <6hex>` in `text`, if present. Stops print the
/// official name (`rv unlock`, Q1); text from before the rename spelled it
/// `rv allow-once`, the permanent alias, so that spelling is read too.
public func allowOnceUnlockCode(in text: String) -> AllowOnceUnlockCode? {
    let markers = [CommandVocabulary.Alias.unlock.invocation, CommandVocabulary.Command.allowOnce.invocation]
    let found = markers.compactMap { text.range(of: $0 + " ") }.min { $0.lowerBound < $1.lowerBound }
    guard let range = found else { return nil }
    let code = String(text[range.upperBound...].prefix(6))
    return AllowOnceUnlockCode(validating: code)
}

// MARK: - Subjects

/// Max characters of the command's first line in hook deny text.
public let hookDenyCommandPreviewLimit = 96

/// First line of `command` for host deny text. Credentials are hidden
/// first (`CommandLineRedaction`: URL userinfo, secret `KEY=`, `Bearer`,
/// known token prefixes), since the stop reaches the host's transcript
/// and the agent. Extra lines and overlong first lines become a trailing
/// ellipsis so Grok/Pi/OpenCode never paste a heredoc body into the
/// transcript. Any newline ends the line, `\r\n` included. Controls are
/// escaped (`DisplayedText.field`), so a command cannot redraw the
/// host's screen.
public func hookDenyCommandPreview(_ command: ShellCommand) -> String {
    var raw = CommandLineRedaction.redact(command.rawValue)
    while let last = raw.last, last.isNewline {
        raw.removeLast()
    }
    var firstLine = ""
    var sawBreak = false
    for ch in raw {
        if ch.isNewline {
            sawBreak = true
            break
        }
        firstLine.append(ch == "\t" ? " " : ch)
    }
    let trimmed = DisplayedText.field(firstLine.trimmingCharacters(in: .whitespaces))
    let clipped = trimmed.count > hookDenyCommandPreviewLimit
        ? String(trimmed.prefix(hookDenyCommandPreviewLimit))
        : trimmed
    if sawBreak || trimmed.count > hookDenyCommandPreviewLimit {
        return clipped + "…"
    }
    return clipped
}

/// A file tool's path for the verdict line, escaped and clipped like a command.
func hookDenyPathPreview(_ path: FileToolPath) -> String {
    hookDenyCommandPreview(ShellCommand(rawValue: path.rawValue))
}

// MARK: - Why, in under ten words

/// Most words a `why` line carries.
public let stopWhyWordLimit = 9

/// What a stop says when the reason gives nothing it may print.
let genericStopWhy = "a rule rv enforces stops it"

/// Why, in under ten words, from a rule's reason. Takes the first sentence,
/// drops the command words the verdict line already shows, keeps the
/// first clause, says "catastrophic" for shouted danger, and clips past
/// nine words with an ellipsis. A reason that names a way past rv
/// (allow-once, unlock, a bypass) is not repeated.
public func stopWhy(_ reason: String, command: ShellCommand?) -> String {
    var text = firstSentence(singleLine(reason))
    if let command {
        text = droppingCommandWords(text, command: command)
    }
    text = firstClause(text)
    text = text
        .replacingOccurrences(of: "is EXTREMELY DANGEROUS", with: "is catastrophic")
        .replacingOccurrences(of: "EXTREMELY DANGEROUS", with: "catastrophic")
    var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard words.isEmpty == false else { return genericStopWhy }
    if words.count > stopWhyWordLimit {
        words = Array(words.prefix(stopWhyWordLimit))
        words[words.count - 1] += "…"
    }
    if let first = words.first, isShouted(first) == false {
        words[0] = first.prefix(1).lowercased() + first.dropFirst()
    }
    let why = words.joined(separator: " ")
    return namesAWayPast(why) ? genericStopWhy : why
}

private func firstSentence(_ text: String) -> String {
    var sentence = text
    if let end = text.firstRange(of: ". ") {
        sentence = String(text[..<end.lowerBound])
    }
    while sentence.hasSuffix(".") {
        sentence.removeLast()
    }
    return sentence.trimmingCharacters(in: .whitespaces)
}

/// `git reset --hard destroys …` under the command `git reset --hard
/// origin/main` reads `destroys …`: the verdict line shows the command.
private func droppingCommandWords(_ text: String, command: ShellCommand) -> String {
    let words = text.split(separator: " ", omittingEmptySubsequences: true)
    // `GITHUB_TOKEN=… git reset --hard` names the same program: leading
    // environment assignments are not words the reason repeats.
    let commandWords = hookDenyCommandPreview(command).split(separator: " ", omittingEmptySubsequences: true)
        .drop(while: isEnvironmentAssignment)
    var shared = 0
    while shared < words.count, shared < commandWords.count,
          words[shared].lowercased() == commandWords[commandWords.startIndex + shared].lowercased()
    {
        shared += 1
    }
    // `rm -rf on root or home paths …` keeps its subject: a bare
    // `on root …` would not read as a reason.
    // One shared word is not the same command (`git clone …` stopped by a
    // `git reset --hard …` reason): drop only a run of two, or the whole
    // command.
    guard shared >= 2 || (shared > 0 && shared == commandWords.count) else { return text }
    guard shared < words.count, prepositions.contains(words[shared].lowercased()) == false else {
        return text
    }
    let rest = words[shared...].joined(separator: " ")
    // `rm -rf is destructive` reads `it is destructive`, not `is destructive`.
    return predicateHeads.contains(words[shared].lowercased()) ? "it \(rest)" : rest
}

/// `NAME=value`, as a shell reads an assignment before the program.
private func isEnvironmentAssignment(_ word: Substring) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
    return name.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
}

private let prepositions: Set<String> = [
    "on", "in", "into", "of", "to", "at", "for", "with", "from", "against", "inside", "outside", "under", "over",
]

private let predicateHeads: Set<String> = ["is", "are", "was", "can", "could", "will", "may", "might", "has", "does"]

private let clauseCuts = [" and requires", ", which", " because", " — ", " - ", "; ", ": ", " (", ", "]

/// The first clause, when it keeps at least three words.
private func firstClause(_ text: String) -> String {
    var clause = text
    for cut in clauseCuts {
        guard let range = clause.range(of: cut) else { continue }
        let head = String(clause[..<range.lowerBound])
        if head.split(separator: " ").count >= 3 {
            clause = head
        }
    }
    return clause
}

private func isShouted(_ word: String) -> Bool {
    let letters = word.unicodeScalars.filter { $0.properties.isAlphabetic }
    return letters.count >= 2 && letters.allSatisfy { $0.properties.isUppercase }
}

/// Words that would read as an instruction to get past rv.
private func namesAWayPast(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("allow-once") || lower.contains("unlock") || lower.contains("redeem")
        || lower.contains("bypass") || text.contains("RV_")
}

/// One line, controls escaped: reasons can come from a repo's policy file.
func singleLine(_ text: String) -> String {
    DisplayedText.field(
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    )
}

// MARK: - Composing stops

/// How a stopped command reached the host: a deny no human can lift, or an
/// ask a human approves (with the record outcome of its pending row).
public enum StopKind: Sendable, Equatable {
    case deny
    case ask(recorded: Bool)
}

/// The stop for an evaluated deny of `command`.
public func stopNotice(
    command: ShellCommand,
    deny: Deny,
    kind: StopKind = .deny,
    unlock: AllowOnceUnlockMint? = nil,
    voice: StopVoice = .plain
) -> StopNotice {
    stopNotice(
        subject: hookDenyCommandPreview(command),
        command: command,
        deny: deny,
        kind: kind,
        unlock: unlock,
        voice: voice
    )
}

/// The stop for a file tool's deny of `path`.
public func fileStopNotice(path: FileToolPath?, deny: Deny, voice: StopVoice = .plain) -> StopNotice {
    stopNotice(
        subject: path.map(hookDenyPathPreview),
        command: nil,
        deny: deny,
        kind: .deny,
        unlock: nil,
        voice: voice
    )
}

private func stopNotice(
    subject: String?,
    command: ShellCommand?,
    deny: Deny,
    kind: StopKind,
    unlock: AllowOnceUnlockMint?,
    voice: StopVoice
) -> StopNotice {
    let advice = voice.advice(deny.ruleID)
    return StopNotice(
        subject: subject,
        rule: deny.ruleID.slashDisplay,
        why: stopWhy(deny.reason, command: command),
        safer: advice?.saferCommand.map(singleLine).flatMap(printableSafer),
        who: stopWho(
            kind: kind, unlock: unlock, ownerStep: ownerRepairStep(in: deny.reason), whoActs: advice?.whoActs,
            owner: voice.owner),
        again: stopStreakNote(voice.streak)
    )
}

/// A safer command is printed only if it is one plain line that does not
/// itself reach for an unlock.
private func printableSafer(_ safer: String) -> String? {
    safer.isEmpty || namesAWayPast(safer) ? nil : safer
}

/// The rv repair commands a deny reason may hand the owner (a judge that
/// could not load says "Ask the owner to run `rv doctor`"). Only these:
/// never an unlock, never anything else a reason could name.
private let ownerRepairSteps = [
    CommandVocabulary.Command.doctor.invocation,
    "\(CommandVocabulary.Command.service.invocation) restart",
    CommandVocabulary.Command.setup.invocation,
]

/// The repair command a reason names in backticks, if it is one of
/// `ownerRepairSteps`; the stop's why is too short to carry it.
func ownerRepairStep(in reason: String) -> String? {
    ownerRepairSteps.first { reason.contains("`\($0)`") }
}

/// Exactly one person and one step: the minted code, an earlier code, the
/// RV app, a repair command the reason names, the pack's `who_acts`, or
/// the owner's own terminal.
private func stopWho(
    kind: StopKind,
    unlock: AllowOnceUnlockMint?,
    ownerStep: String?,
    whoActs: String?,
    owner: OwnerName
) -> String {
    switch unlock {
    case .code(let code):
        return unlockLine(for: code, owner: owner)
    case .earlierPending:
        return earlierPendingUnlockLine(owner: owner)
    case nil:
        break
    }
    #if os(macOS)
    if case .ask(recorded: true) = kind {
        return approveInRVLine(owner: owner)
    }
    #endif
    if let ownerStep {
        return ownerRunsLine(ownerStep, owner: owner)
    }
    if let whoActs, whoActs.trimmingCharacters(in: .whitespaces).isEmpty == false {
        return whoActsLine(whoActs, owner: owner)
    }
    return ownTerminalLine(owner: owner)
}

/// The stop for an indeterminate verdict: rv could not finish, so the
/// owner runs it. Names the reason's id, as `rv log` records it. A nil
/// reason is an evaluation that reached deny dispatch without a verdict.
public func indeterminateStopNotice(
    _ reason: IndeterminateReason?,
    command: ShellCommand?,
    voice: StopVoice = .plain
) -> StopNotice {
    if reason == .selfProtection {
        return selfProtectionStopNotice(command: command, voice: voice)
    }
    return StopNotice(
        subject: command.map(hookDenyCommandPreview),
        rule: reason.map(indeterminateStopRule) ?? "rv.indeterminate/incomplete",
        why: reason.map(indeterminateStopWhy) ?? "rv could not finish checking it",
        who: ownTerminalLine(owner: voice.owner),
        again: stopStreakNote(voice.streak)
    )
}

/// `rv.indeterminate/<reason>`, the id the denial ledger records
/// (`rv.indeterminate:<reason>`); the observe floor keeps its own id.
public func indeterminateStopRule(_ reason: IndeterminateReason) -> String {
    if reason == .observeUnanalyzable {
        return RuleID(rawValue: reason.rawValue)?.slashDisplay ?? reason.rawValue
    }
    return "rv.indeterminate/\(reason.rawValue)"
}

/// Why rv could not finish, in under ten words.
public func indeterminateStopWhy(_ reason: IndeterminateReason) -> String {
    switch reason {
    case .budgetExhausted: "rv ran out of time checking it"
    case .commandTooLarge: "it is too large for rv to check"
    case .corePacksUnavailable: "rv's core rules did not load"
    case .inlineProgramNeedsJudge: "rv could not score its inline program"
    case .selfProtection: "it would change rv itself"
    case .packageScriptUnresolved: "rv could not resolve its package script"
    case .unresolvedInvocation: "rv could not tell what program it runs"
    case .observeUnanalyzable: "rv could not see what this command runs"
    }
}

/// A stop rv raises about the hook call itself, not the command.
public enum HookCallStop: Sendable, Equatable {
    /// The payload could not be decoded.
    case malformed(HookMalformation)
    /// rvd ran past its deadline and committed nothing.
    case timedOut
}

/// The stop for `stop`, in the same shape. No command to show.
public func hookCallStopNotice(_ stop: HookCallStop, voice: StopVoice = .plain) -> StopNotice {
    let doctor = CommandVocabulary.Command.doctor.invocation
    switch stop {
    case .malformed(.unreadable):
        return StopNotice(
            subject: nil, rule: "rv.hook/unreadable",
            why: "rv could not read this hook request",
            who: ownerRunsLine(doctor, owner: voice.owner))
    case .malformed(.missingCommand):
        return StopNotice(
            subject: nil, rule: "rv.hook/no-command",
            why: "the shell hook carried no command",
            who: ownerRunsLine(doctor, owner: voice.owner))
    case .timedOut:
        return StopNotice(
            subject: nil, rule: "rv.timeout",
            why: "rv timed out and committed nothing",
            who: ownerRunsLine(doctor, owner: voice.owner))
    }
}

/// Hook-voice text for a payload addressed to this host that could not be
/// decoded. Fail-closed twin of the indeterminate stop.
public func malformedHookSentence(_ malformation: HookMalformation, voice: StopVoice = .plain) -> String {
    hookCallStopNotice(.malformed(malformation), voice: voice).text
}

// MARK: - Text

/// The stop text for a shell deny.
public func hostDenyLine(
    command: ShellCommand,
    deny: Deny,
    kind: StopKind = .deny,
    unlock: AllowOnceUnlockMint? = nil,
    voice: StopVoice = .plain
) -> String {
    stopNotice(command: command, deny: deny, kind: kind, unlock: unlock, voice: voice).text
}

/// The stop text for a file tool's deny.
public func hostFileDenyLine(path: FileToolPath? = nil, deny: Deny, voice: StopVoice = .plain) -> String {
    fileStopNotice(path: path, deny: deny, voice: voice).text
}

/// Host text for a verdict, or nil on allow (including a medium/low match).
/// Switch on `Decision` first: nil means allow only after that switch.
public func hostDenyText(
    from result: EvaluationResult,
    command: ShellCommand,
    voice: StopVoice = .plain
) -> String? {
    switch result.decision {
    case .allow:
        return nil
    case .indeterminate(let reason):
        return indeterminateStopNotice(reason, command: command, voice: voice).text
    case .deny(let deny):
        return hostDenyLine(command: command, deny: deny, voice: voice)
    }
}
