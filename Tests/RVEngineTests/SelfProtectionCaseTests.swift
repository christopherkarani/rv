import Testing
import RVDomain
@testable import RVEngine

private func selfProtectionPacks() -> [PackSnapshot] {
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

private func runEngine(_ command: String) throws -> EvaluationResult {
    let packs = selfProtectionPacks()
    let engine = ICUPatternEngine()
    let compiled = try CompiledPacks<ICUCompiledPattern>.compile(packs: packs, using: engine)
    return evaluate(
        EvaluationRequest(command: ShellCommand(rawValue: command), enabledPacks: dayOnePackIDs),
        packs: packs,
        engine: engine,
        compiled: compiled
    )
}

/// Case-insensitive APFS runs `RV`, `Rv-Cli`, `BASH` as the same binaries.
struct SelfProtectionCaseTests {
    static let weakening: [String] = [
        "RV packs disable core.filesystem",
        "Rv packs disable core.filesystem",
        "rv-CLI packs disable core.git",
        "Rv-Cli allow-once redeem 123456",
        "/usr/local/bin/RV uninstall",
        "~/.local/bin/RV-CLI uninstall",
        "BASH -c 'rv packs disable core.git'",
        "Bash -c 'RV packs disable core.git'",
        "/bin/ZSH -c 'Rv uninstall'",
        "r\\v packs disable core.git",
        "R\\V packs disable core.git",
        "SUDO RV uninstall",
        "Env RV_X=1 RV safety normal",
        // APFS folds U+017F and U+FB01: `baſh`, `ſudo`, `ﬁsh` resolve to bash, sudo, fish.
        "baſh -c 'rv uninstall'",
        "/bin/baſh -c 'rv packs disable core.git'",
        "ﬁsh -c 'rv uninstall'",
        "ſudo rv uninstall",
        // Backslash-escaped launchers (`\command` skips aliases).
        "\\command rv uninstall",
        "\\sudo rv uninstall",
        "su\\do RV uninstall",
        "\\env rv uninstall",
        "\\exec rv uninstall",
        "\\timeout 5 rv uninstall",
        // Escaped verbs, ANSI-C quoting, dynamic/glob heads, launcher payloads.
        "rv un\\install",
        "rv packs dis\\able core.git",
        "rv allow-once re\\deem 123456",
        "rv policy app\\ly",
        "$'rv' uninstall",
        "rv $'uninstall'",
        "$'\\x72v' packs disable core.git",
        "$RV uninstall",
        "${RV} uninstall",
        "$(which rv) uninstall",
        "`command -v rv` packs disable core.git",
        "/usr/local/bin/r? uninstall",
        "r[v] uninstall",
        "env -S 'rv uninstall'",
        "env --split-string='rv uninstall'",
        "bash -c -- 'rv uninstall'",
        "bash -c -e 'rv uninstall'",
        "csh -c 'rv uninstall'",
        "tcsh -c 'rv uninstall'",
        "eval 'rv uninstall'",
        // Round 2: launcher heads, option clusters, globs, continuations, redirects.
        "$'sudo' rv uninstall",
        "$'env' rv uninstall",
        "$'command' rv uninstall",
        "$'nohup' rv uninstall",
        "$'exec' rv uninstall",
        "$'time' rv uninstall",
        "$'timeout' 5 rv uninstall",
        "$'bash' -c 'rv uninstall'",
        "$'sh' -c 'rv uninstall'",
        "$'eval' 'rv uninstall'",
        "$'env' -S 'rv uninstall'",
        "env -iS 'rv uninstall'",
        "env -vS 'rv uninstall'",
        "env \\-S 'rv uninstall'",
        "env -P /usr/bin -S 'rv uninstall'",
        "bash -cl 'rv uninstall'",
        "bash -ce 'rv uninstall'",
        "bash -cex 'rv uninstall'",
        "bash -ci 'rv uninstall'",
        "bash \\-c 'rv uninstall'",
        "sudo \\-n rv uninstall",
        "env -S'rv' uninstall",
        "env -S 'rv' uninstall",
        "rv {uninstall,--yes}",
        "rv packs {disable,core.git}",
        "rv unin*",
        "rv ?ninstall",
        "rv [u]ninstall",
        "rv packs disa*",
        "rv policy a*",
        "rv allow-once r*",
        "rv \\\nuninstall",
        "rv un\\\ninstall",
        "rv packs \\\ndisable core.git",
        "echo hi; \\\nrv uninstall",
        "eval -- 'rv uninstall'",
        "eval $'rv\\x20uninstall'",
        "busybox sh -c 'rv uninstall'",
        "busybox ash -c 'rv uninstall'",
        "ksh93 -c 'rv uninstall'",
        "rbash -c 'rv uninstall'",
        "yash -c 'rv uninstall'",
        "pwsh -c 'rv uninstall'",
        "pwsh -Command 'rv uninstall'",
        "nu -c 'rv uninstall'",
        "xonsh -c 'rv uninstall'",
        "</dev/null rv uninstall",
        "2>&1 rv uninstall",
        "< /dev/null rv uninstall",
        "sudo --user root rv uninstall",
        "sudo --group wheel rv uninstall",
        "sudo --host h rv uninstall",
        "env --split-str='rv uninstall'",
        "env --sp='rv uninstall'",
        "rv packs --search x disable core.git",
        "rv --config x uninstall",
        "$(which /usr/local/bin/rv) uninstall",
        "$HOME/bin/r? uninstall",
        "$HOME/bin/rv uninstall",
        "bash -c -o pipefail 'rv uninstall'",
        "bash -c -O extglob 'rv uninstall'",
    ]

    @Test("case-folded and escaped rv invocations still hit the self-protection floor", arguments: weakening)
    func weakeningIsIndeterminate(command: String) throws {
        let result = try runEngine(command)
        #expect(result.decision == .indeterminate(.selfProtection), "\(command)")
    }

    @Test("case-folded harmless rv invocations stay allowed")
    func harmlessStaysAllowed() throws {
        for command in ["RV packs list", "Rv-Cli doctor", "BASH -c 'RV safety strict'",
            "rvm use 3.3", "./server --port 80", "cargo run --bin rvx", "grep -i rv notes.txt", "echo rv uninstall", "rv --version", "rv status",
            "rv packs list $X", "$HOME/bin/tool \"$1\"", "eval \"$(direnv hook bash)\"", "bash -lc 'make test'", "env -i PATH=/usr/bin make", "</dev/null swift test", "rv mcp check \"$s\"", "rv policy show $X"] {
            #expect(try runEngine(command).decision == .allow, "\(command)")
        }
    }
}
