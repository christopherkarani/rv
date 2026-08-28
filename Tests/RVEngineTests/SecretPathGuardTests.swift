import Testing
import RVDomain
@testable import RVEngine

private func samplePacks() -> [PackSnapshot] {
    [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm", "dd"],
            safe: [NamedPattern(name: "rm-rf-tmp", pattern: #"^rm\s+-rf\s+/tmp/"#)],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-general",
                    pattern: #"rm\s+-rf"#,
                    severity: .high,
                    reason: "rm -rf is destructive"
                )
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [NamedPattern(name: "checkout-new-branch", pattern: #"git\s+checkout\s+-b\s+"#)],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "git reset --hard destroys uncommitted changes"
                ),
                DestructiveRule(
                    name: "stash-drop",
                    pattern: #"git\s+stash\s+drop"#,
                    severity: .medium,
                    reason: "git stash drop deletes a single stash"
                ),
            ]
        ),
    ]
}

private func run(
    _ command: String,
    packs: [PackSnapshot]? = nil,
    secrets: SecretPathCatalog = .dayOne,
    budget: EvaluationBudget? = nil
) throws -> EvaluationResult {
    let packs = packs ?? samplePacks()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(
            command: ShellCommand(rawValue: command),
            enabledPacks: dayOnePackIDs,
            budget: budget
        ),
        packs: packs,
        secrets: secrets,
        patterns: engine,
        compiled: compiled
    )
}

struct SecretPathGuardTests {
    struct DenyRow: Sendable, CustomTestStringConvertible {
        var command: String
        var ruleID: String
        var testDescription: String { "\(command) → \(ruleID)" }
    }

    struct AllowRow: Sendable, CustomTestStringConvertible {
        var command: String
        var testDescription: String { command }
    }

    static let denyRows: [DenyRow] = [
        .init(command: "cat .env", ruleID: "core.secrets:env"),
        .init(command: "xxd .env", ruleID: "core.secrets:env"),
        .init(command: "cat ~/.ssh/id_rsa", ruleID: "core.secrets:id-rsa"),
        .init(command: "dd if=.env of=/tmp/x", ruleID: "core.secrets:env"),
        .init(command: "rg --files ~/.ssh", ruleID: "core.secrets:home-ssh"),
        .init(command: "cat ~/.pi/agent/auth.json", ruleID: "core.secrets:host-pi-auth"),
        .init(command: "cat .env.local", ruleID: "core.secrets:env-variant"),
        .init(command: "cat ~/.npmrc", ruleID: "core.secrets:npmrc"),
        .init(command: "cat $HOME/.ssh/config", ruleID: "core.secrets:home-ssh"),
        .init(command: "cat ${HOME}/.aws/config", ruleID: "core.secrets:home-aws"),
        .init(command: "rg -e foo .env", ruleID: "core.secrets:env"),
        .init(command: "rg -f .env", ruleID: "core.secrets:env"),
        .init(command: "grep -f .env pattern", ruleID: "core.secrets:env"),
        .init(command: "rm .env", ruleID: "core.secrets:env"),
        .init(command: "find ~/.ssh -type f", ruleID: "core.secrets:home-ssh"),
        .init(command: "echo hello && cat .env", ruleID: "core.secrets:env"),
        .init(command: "git stash drop .env", ruleID: "core.secrets:env"),
        .init(command: "rm -rf /tmp/.env", ruleID: "core.secrets:env"),
        .init(command: "cat ~/.gnupg/secring.gpg", ruleID: "core.secrets:home-gnupg"),
        .init(command: "cat ~/Library/Keychains/login.keychain-db", ruleID: "core.secrets:home-keychains"),
        .init(command: "cat $HOME/.local/share/keyrings/login.keyring", ruleID: "core.secrets:home-keyrings"),
    ]

    static let allowRows: [AllowRow] = [
        .init(command: "echo .env"),
        .init(command: "printf .env"),
        .init(command: "cat .gitignore"),
        .init(command: "cat .env.example"),
        .init(command: "cat .env.sample"),
        .init(command: "cat .env.template"),
        .init(command: "cat .env.defaults"),
        .init(command: "find . -name .env"),
        .init(command: "rg .env"),
        .init(command: "grep .env README.md"),
        .init(command: "git status"),
        .init(command: "cat .env.example.local"),
    ]

    @Test(arguments: denyRows)
    func evaluate_deniesSecretPath(_ row: DenyRow) throws {
        let result = try run(row.command)
        guard case .deny(let deny, let matched) = result.outcome else {
            Issue.record("expected deny for \(row.command), got \(String(describing: result.outcome))")
            return
        }
        #expect(deny.ruleID.rawValue == row.ruleID)
        #expect(deny.reason == "Access to a sensitive path is not allowed.")
        let match = try #require(matched)
        #expect(match.ruleID.rawValue == row.ruleID)
        #expect(match.severity == .high)
        #expect(match.regex == nil)
        #expect(match.searchText == result.matchingView.rawValue)
        #expect(match.packID == .coreSecrets)
    }

    @Test(arguments: allowRows)
    func evaluate_allowsNonSecretPath(_ row: AllowRow) throws {
        let result = try run(row.command)
        #expect(result.decision == .allow, "\(row.command) got \(String(describing: result.decision))")
    }

    @Test func evaluate_packDeny_keepsGitRuleID() throws {
        let result = try run("git reset --hard")
        guard case .deny(let deny, _) = result.outcome else {
            Issue.record("expected pack deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func evaluate_packDeny_keepsFilesystemRuleID() throws {
        let result = try run("rm -rf ~/.ssh")
        guard case .deny(let deny, _) = result.outcome else {
            Issue.record("expected pack deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.filesystem:rm-rf-general")
    }

    @Test func evaluate_emptyCatalog_matchesPreGuardAllow() throws {
        let result = try run("cat .env", secrets: .empty)
        #expect(result.decision == .allow)
        #expect(result.outcome == .quickRejected)
    }

    @Test func evaluate_emptyCatalog_stillDeniesPackHit() throws {
        let withGuard = try run("git reset --hard")
        let withoutGuard = try run("git reset --hard", secrets: .empty)
        #expect(withGuard.outcome == withoutGuard.outcome)
        guard case .deny(let deny, _) = withoutGuard.outcome else {
            Issue.record("expected pack deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func evaluate_secretPath_doesNotConsumeBudget() throws {
        let result = try run("cat .env", budget: EvaluationBudget(maxPatternAttempts: 0))
        guard case .deny(let deny, _) = result.outcome else {
            Issue.record("expected secret-path deny, got \(String(describing: result.outcome))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.secrets:env")
    }

    @Test func evaluate_oversize_skipsGuard() throws {
        let raw = "cat .env " + String(repeating: "a", count: commandByteCap)
        let result = try run(raw)
        #expect(result.outcome == .indeterminate(.commandTooLarge))
    }

    @Test func evaluate_emptyCommand_skipsGuard() throws {
        let result = try run("   ")
        #expect(result.outcome == .plain)
    }

    @Test func secretPathGuard_capsCandidatesAt64() {
        let ignored = (0..<64).map { _ in "x" }.joined(separator: " ")
        let overflow = MatchingView("cat \(ignored) .env")
        #expect(SecretPathGuard.firstHit(in: overflow, catalog: .dayOne) == nil)

        let within = (0..<63).map { _ in "x" }.joined(separator: " ")
        let hit = SecretPathGuard.firstHit(
            in: MatchingView("cat \(within) .env"),
            catalog: .dayOne
        )
        #expect(hit?.ruleID.rawValue == "core.secrets:env")
    }

    @Test func secretPathGuard_echoAndPrintfYieldNoCandidates() {
        #expect(SecretPathGuard.firstHit(in: MatchingView("ECHO .env"), catalog: .dayOne) == nil)
        #expect(
            SecretPathGuard.firstHit(in: MatchingView("/usr/bin/printf .env"), catalog: .dayOne) == nil
        )
    }

    @Test func secretPathGuard_ddEqualsOperand() {
        let hit = SecretPathGuard.firstHit(in: MatchingView("dd if=.env of=/tmp/x"), catalog: .dayOne)
        #expect(hit?.ruleID.rawValue == "core.secrets:env")
        #expect(hit?.matchedText == ".env")
    }

    @Test func secretPathGuard_grepFirstPositionalIsPattern() {
        #expect(SecretPathGuard.firstHit(in: MatchingView("grep .env"), catalog: .dayOne) == nil)
        #expect(SecretPathGuard.firstHit(in: MatchingView("rg .env"), catalog: .dayOne) == nil)
        let afterRegexp = SecretPathGuard.firstHit(
            in: MatchingView("grep -e foo .env"),
            catalog: .dayOne
        )
        #expect(afterRegexp?.ruleID.rawValue == "core.secrets:env")
    }

    @Test func secretPathGuard_findNameValueIsNotCandidate() {
        #expect(SecretPathGuard.firstHit(in: MatchingView("find . -name .env"), catalog: .dayOne) == nil)
        #expect(SecretPathGuard.firstHit(in: MatchingView("find . -iname .env"), catalog: .dayOne) == nil)
        #expect(
            SecretPathGuard.firstHit(in: MatchingView("find . -path ~/.ssh"), catalog: .dayOne) == nil
        )
    }
}
