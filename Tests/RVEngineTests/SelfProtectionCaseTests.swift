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
        // Round 3: real newline separators, policy draft vars, mid-argv redirects, brace heads.
        "echo \\\\\nrv uninstall",
        "true \\\\\nrv uninstall",
        "bash -c 'echo \\\\\nrv uninstall'",
        "if true; then echo a \\\\\nrv uninstall; fi",
        "echo hi\\\\\n rv uninstall",
        "echo hi \\\\\nrv uninstall",
        "echo \\\r\nrv uninstall",
        "S=--save; rv policy draft --english \"allow rm\" $S",
        "rv policy draft $S",
        "rv policy draft --english x --repo $S",
        "rv 2>&1 packs disable core.git",
        "rv </dev/null uninstall",
        "rv >>log uninstall",
        "rv >&2 uninstall",
        "rv secrets hook 2>&1 uninstall",
        "rv < /dev/null uninstall",
        "{rv,uninstall}",
        "{rv,packs,disable,core.git}",
        "{rv,uninstall,}",
        // Round 4: quoted redirect operators, brace heads anywhere, continuation parity.
        "rv --config '>' uninstall",
        "rv --config '>' packs disable core.git",
        "rv --config '>' policy apply",
        "rv --home '>' safety lower",
        "rv packs --x '>' disable core.git",
        "rv --config \">\" uninstall",
        "rv --config \">\" packs disable core.git",
        "rv --config \">\" policy apply",
        "rv --home \">\" safety lower",
        "rv packs --x \">\" disable core.git",
        "rv --config '<<<' uninstall",
        "rv --config '<<<' packs disable core.git",
        "rv --config '<<<' policy apply",
        "rv --home '<<<' safety lower",
        "rv packs --x '<<<' disable core.git",
        "rv --config '>&' uninstall",
        "rv --config '>&' packs disable core.git",
        "rv --config '>&' policy apply",
        "rv --home '>&' safety lower",
        "rv packs --x '>&' disable core.git",
        "echo a; {rv,uninstall}",
        "echo;{rv,uninstall}",
        "echo&&{rv,uninstall}",
        "echo|{rv,uninstall}",
        "{rv,uninstall};echo",
        "echo $({rv,uninstall})",
        "echo `{rv,uninstall}`",
        "(echo; {rv,uninstall})",
        "{ {rv,uninstall}; }",
        "if true; then {rv,uninstall}; fi",
        "while true; do {rv,uninstall}; done",
        "f() { {rv,uninstall}; }; f",
        "bash -c 'echo; {rv,uninstall}'",
        "exec {rv,uninstall}",
        "xargs {rv,uninstall}",
        "{rv,uninstall}>f",
        "{sh,-c,rv\\ uninstall}",
        "{r,}v uninstall",
        "r{v,} uninstall",
        "echo x {a0,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19,a20,a21,a22,a23,a24,a25,a26,a27,a28,a29,a30,a31,a32,a33,a34,a35,a36,a37,a38,a39,a40,a41,a42,a43,a44,a45,a46,a47,a48,a49,a50,a51,a52,a53,a54,a55,a56,a57,a58,a59,a60,a61,a62,a63,a64,a65}",
        "echo \\\\\n\\\nrv uninstall",
        "echo \\\\\nr\\\nv uninstall",
        // `rv host mode`: anything but `block` is floored at the door.
        "rv host mode claude off",
        "RV host mode cursor observe",
        "sh -c 'rv host mode codex off'",
        "rv host mode claude",
        "rv host mode claude 'off'",
        "rv host mode claude of\\f",
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
            "ls {src,Tests}", "echo {a,b}", "cp f{,.bak}", "mkdir -p a/{b,c}", "git diff {main,HEAD}", "touch {1..3}.txt", "rv packs list '>' x",
            "rv policy draft --english x", "rv packs list 2>&1", "echo {a,b}", "ls {src,Tests}", "echo hi \\\nthere",
            "rv packs list $X", "$HOME/bin/tool \"$1\"", "bash -lc 'make test'", "env -i PATH=/usr/bin make", "</dev/null swift test", "rv mcp check \"$s\"", "rv policy show $X",
            "rv host list", "RV host mode claude block", "rv host mode cursor block --json"] {
            #expect(try runEngine(command).decision == .allow, "\(command)")
        }
    }

    @Test("huge option clusters and operand lists evaluate in bounded time")
    func hugeInputsAreFast() {
        let cluster = String(repeating: "i", count: 64_000)
        let digits = String(repeating: "1", count: 64_000)
        let dynamic = (0..<4_000).map { "$a\($0)" }.joined(separator: " ")
        let literal = (0..<8_000).map { _ in "packs" }.joined(separator: " ")
        let commands = [
            "env -\(cluster) ls", "sudo -\(String(repeating: "n", count: 64_000)) ls", "nice -\(digits) ls",
            dynamic, "rv --x \(literal)",
        ]
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for command in commands { _ = SelfProtectionGuard.weakensPolicy(ShellCommand(rawValue: command)) }
        }
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}
