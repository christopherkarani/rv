import Testing
import RVDomain
@testable import RVEngine

@Test func normalize_stripsWrappersAndPath() {
    #expect(Normalize.matchingView(of: "  sudo git reset --hard  ") == "git reset --hard")
    #expect(Normalize.matchingView(of: "env GIT_DIR=.git git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "command git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "\\git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "/usr/bin/git reset --hard") == "git reset --hard")
}

@Test func normalize_keepsCommandQuery() {
    #expect(Normalize.matchingView(of: "command -v git") == "command -v git")
    #expect(Normalize.matchingView(of: "command -V git") == "command -V git")
}

@Test func normalize_roleAwareQuotes() {
    #expect(Normalize.matchingView(of: "\"git\" reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git reset '--hard'") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git \"reset\" --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "sudo \"git\" reset --hard") == "git reset --hard")
    let chained = Normalize.matchingView(of: "echo hello && \"git\" reset --hard")
    #expect(chained.rawValue.contains("git reset --hard"))
    let echoed = Normalize.matchingView(of: "echo \"git reset --hard\"")
    #expect(!echoed.rawValue.contains("reset"))
    let commit = Normalize.matchingView(of: "git commit -m \"git push --force\"")
    #expect(!commit.rawValue.contains("--force"))
    let attached = Normalize.matchingView(of: "git commit --message=\"git reset --hard\"")
    #expect(!attached.rawValue.contains("reset"))
    let sudoEcho = Normalize.matchingView(of: "sudo echo \"git reset --hard\"")
    #expect(!sudoEcho.rawValue.contains("reset"))
    let envEcho = Normalize.matchingView(of: "env echo \"git reset --hard\"")
    #expect(!envEcho.rawValue.contains("reset"))
}

@Test func normalize_tokenizerPreservesBoundariesAndInlineCode() {
    let tokens = tokenizeCommand(#""git" reset --'hard' "$(git reset --hard)" `git status`"#)

    #expect(tokens.map(\.decoded) == [
        "git",
        "reset",
        "--hard",
        "$(git reset --hard)",
        "`git status`",
    ])
    #expect(tokens.map(\.wasQuoted) == [true, false, true, true, false])
}

@Test func normalize_roleAwareQuotesPreservesWrappersAndSeparators() {
    #expect(applyRoleAwareQuotes("sudo -E \"git\" reset --'hard'") == "sudo -E git reset --hard")
    #expect(applyRoleAwareQuotes("env FOO=bar \"git\" reset --\"hard\"") == "env FOO=bar git reset --hard")
    #expect(
        applyRoleAwareQuotes("echo \"git reset --hard\" && \"git\" reset --'hard'")
            == "echo " + String(repeating: " ", count: 16) + " && git reset --hard"
    )
    #expect(applyRoleAwareQuotes("echo \"$(git reset --hard)\" | printf `git status`")
        == "echo $(git reset --hard) | printf `git status`")
}

@Test func normalize_roleAwareQuotesMasksOnlyDataRoles() {
    let commit = String(repeating: " ", count: 16)
    #expect(applyRoleAwareQuotes("git commit -m \"git reset --hard\"") == "git commit -m " + commit)
    #expect(applyRoleAwareQuotes("git commit --message=\"git reset --hard\"") == "git commit --message=" + commit)
    #expect(applyRoleAwareQuotes("rg -e \"git reset --hard\"") == "rg -e " + commit)
    #expect(applyRoleAwareQuotes("git reset \"--hard\"") == "git reset --hard")
}

@Test func normalize_preservesEmptyQuotedArguments() {
    let tokens = tokenizeCommand("git commit -m \"\" \"git push --force\"")
    #expect(tokens.map(\.decoded) == ["git", "commit", "-m", "", "git push --force"])
    #expect(
        applyRoleAwareQuotes("git commit -m \"\" \"git push --force\"")
            == "git commit -m   git push --force"
    )
}

@Test func normalize_concatenatesAdjacentQuotes() {
    #expect(Normalize.matchingView(of: "git reset --'hard'") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git reset --\"hard\"") == "git reset --hard")
}

@Test func normalize_concatenatesGluedQuotedRmFlags() {
    #expect(tokenizeCommand("rm -r'f' /").map(\.decoded) == ["rm", "-rf", "/"])
    #expect(tokenizeCommand("rm -'r'f /").map(\.decoded) == ["rm", "-rf", "/"])
    #expect(Normalize.matchingView(of: "rm -r'f' /") == "rm -rf /")
    #expect(Normalize.matchingView(of: "rm -'r'f /") == "rm -rf /")
    #expect(applyRoleAwareQuotes("rm -r'f' /") == "rm -rf /")
    #expect(applyRoleAwareQuotes("rm -'r'f /") == "rm -rf /")
}

@Test func normalize_doesNotStripRedirectAsArgv0() {
    #expect(Normalize.matchingView(of: ">/etc/passwd") == ">/etc/passwd")
    #expect(Normalize.matchingView(of: "1>/etc/passwd") == "1>/etc/passwd")
    #expect(Normalize.matchingView(of: "&>/etc/passwd") == "&>/etc/passwd")
}

@Test func normalize_doesNotMaskSubstitutions() {
    #expect(Normalize.matchingView(of: "echo $(git reset --hard)").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo `git reset --hard`").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"$(git reset --hard)\"").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"`git reset --hard`\"").rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotExpandTmpdir() {
    #expect(Normalize.matchingView(of: "rm -rf ${TMPDIR}/build") == "rm -rf ${TMPDIR}/build")
}

@Test func normalize_masksQuotedInterpreterProgramText() {
    let python = Normalize.matchingView(of: #"python3 -c "print('git reset --hard')""#)
    #expect(!python.rawValue.contains("reset"))
    #expect(python.rawValue.contains("python3"))

    let node = Normalize.matchingView(of: #"node -e "console.log('git reset --hard')""#)
    #expect(!node.rawValue.contains("reset"))

    let ruby = Normalize.matchingView(of: #"ruby -e "puts 'git reset --hard'""#)
    #expect(!ruby.rawValue.contains("reset"))
}

@Test func normalize_doesNotMaskSubstitutionInInterpreterDashC() {
    let view = Normalize.matchingView(of: #"python3 -c "$(git reset --hard)""#)
    #expect(view.rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotMaskUnquotedTokenAfterInterpreterFlag() {
    let view = Normalize.matchingView(of: "python3 -c git reset --hard")
    #expect(view.rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotMaskQuotedInterpreterHeredocBody() {
    let quoted = Normalize.matchingView(
        of: "python3 <<'PY'\nprint('git reset --hard')\nPY"
    )
    #expect(quoted.rawValue.contains("git reset --hard"))
    #expect(quoted.rawValue.contains("python3"))

    let after = Normalize.matchingView(
        of: "python3 <<'PY'\nprint(1)\nPY\ngit reset --hard"
    )
    #expect(after.rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotMaskNodeAttachedEval() {
    let view = Normalize.matchingView(
        of: #"node --eval=require('child_process').execSync('git reset --hard')"#
    )
    #expect(view.rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotMaskBashOrUnquotedInterpreterHeredoc() {
    let bash = Normalize.matchingView(of: "bash <<'EOF'\ngit reset --hard\nEOF")
    #expect(bash.rawValue.contains("git reset --hard"))

    let sh = Normalize.matchingView(of: "sh <<'EOF'\ngit reset --hard\nEOF")
    #expect(sh.rawValue.contains("git reset --hard"))

    let unquoted = Normalize.matchingView(
        of: "python3 <<PY\nprint('git reset --hard')\nPY"
    )
    #expect(unquoted.rawValue.contains("git reset --hard"))
}

@Test func splitSegments_respectsQuotesAndByteOperators() {
    #expect(splitSegments("echo a && git reset --hard") == ["echo a", "git reset --hard"])
    #expect(splitSegments("echo 'a && b' | cat") == ["echo 'a && b'", "cat"])
    #expect(splitSegments(#"python3 -c "print(1)"; git status"#) == [
        #"python3 -c "print(1)""#,
        "git status",
    ])
}

@Test func evaluate_gluedQuotedRmFlags_denyAsRmRf() throws {
    for command in ["rm -r'f' /", "rm -'r'f /"] {
        let result = try evaluateNormalized(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(command) must deny, got \(result.decision)")
            continue
        }
        #expect(deny.ruleID.rawValue == "core.filesystem:rm-rf-root-home")
        #expect(result.matchingView == "rm -rf /")
    }
}

@Test func normalize_tokenizerKeepsDollarOnAnsiCQuotes() {
    let tokens = tokenizeCommand("rm $'-rf' /")
    #expect(tokens.map(\.decoded) == ["rm", "$-rf", "/"])
    #expect(tokens.map(\.wasQuoted) == [false, true, false])
    #expect(tokens[1].wasAnsiC)

    let payload = tokenizeCommand("bash -c $'git reset --hard'")
    #expect(payload.map(\.decoded) == ["bash", "-c", "$git reset --hard"])
    #expect(payload[2].wasQuoted)
    #expect(payload[2].wasAnsiC)
    #expect(payload[2].decoded.contains("$"))
}

@Test func normalize_optionPositionAnsiC_decodesFlags() {
    #expect(Normalize.matchingView(of: "rm $'-rf' /") == "rm -rf /")
    #expect(Normalize.matchingView(of: #"rm $'\x2d\x72\x66' /"#) == "rm -rf /")
    #expect(Normalize.matchingView(of: #"rm $'-\x72\x66' /"#) == "rm -rf /")
    #expect(applyRoleAwareQuotes("rm $'-rf' /") == "rm -rf /")
    #expect(applyRoleAwareQuotes(#"rm $'\x2d\x72\x66' /"#) == "rm -rf /")
}

@Test func normalize_wholeCommandAnsiC_decodesRmRf() {
    #expect(Normalize.matchingView(of: #"$'\x72m -rf /'"#) == "rm -rf /")
}

@Test func normalize_dataRoleAnsiC_staysMasked() {
    let echoed = Normalize.matchingView(of: "echo $'git reset --hard'")
    #expect(!echoed.rawValue.contains("reset"))
    let printed = Normalize.matchingView(of: "printf $'git reset --hard'")
    #expect(!printed.rawValue.contains("reset"))
    let commit = Normalize.matchingView(of: "git commit -m $'git reset --hard'")
    #expect(!commit.rawValue.contains("reset"))
    let search = Normalize.matchingView(of: "rg -e $'git reset --hard'")
    #expect(!search.rawValue.contains("reset"))
}

@Test func normalize_bashDashCAnsiC_staysUnwrapLimited() {
    let view = Normalize.matchingView(of: "bash -c $'git reset --hard'")
    #expect(view.rawValue.contains("bash"))
    #expect(view.rawValue.contains("$"))
    let outcome = unwrapCommand(ShellCommand(rawValue: "bash -c $'git reset --hard'"))
    guard case .limited = outcome else {
        Issue.record("ANSI-C -c payload must stay unwrapLimited, got \(outcome)")
        return
    }
}

@Test func evaluate_optionPositionAnsiCRmFlags_denyAsRmRf() throws {
    for command in ["rm $'-rf' /", #"rm $'\x2d\x72\x66' /"#, #"rm $'-\x72\x66' /"#] {
        let result = try evaluateNormalized(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("\(command) must deny, got \(result.decision)")
            continue
        }
        #expect(deny.ruleID.rawValue == "core.filesystem:rm-rf-root-home")
        #expect(result.matchingView == "rm -rf /")
    }
}

@Test func evaluate_dataRoleAnsiCEcho_allows() throws {
    let result = try evaluateNormalized("echo $'git reset --hard'")
    #expect(result.decision == .allow)
    #expect(!result.matchingView.rawValue.contains("reset"))
}

private func evaluateNormalized(_ command: String) throws -> EvaluationResult {
    let packs = [
        PackSnapshot(
            id: .coreFilesystem,
            name: "fs",
            description: "fs",
            keywords: ["rm"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "rm-rf-root-home",
                    pattern: #"rm\s+-rf\s+/"#,
                    severity: .critical,
                    reason: "EXTREMELY DANGEROUS"
                ),
            ]
        ),
        PackSnapshot(
            id: .coreGit,
            name: "git",
            description: "git",
            keywords: ["git"],
            safe: [],
            destructive: [
                DestructiveRule(
                    name: "reset-hard",
                    pattern: #"git\s+reset\s+--hard"#,
                    severity: .critical,
                    reason: "destroys uncommitted changes"
                ),
            ]
        ),
    ]
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        patterns: engine,
        compiled: compiled
    )
}
