import Testing
import RVDomain
import RVEngine

private func isDenied(_ result: EvaluationResult) -> Bool {
    if case .deny = result.decision { return true }
    return false
}

private let unverifiedAlias = "core.git:git-alias-semantic-unverified"

/// Follow-up to "Gate masking bypasses": git config the gate cannot see,
/// wrapper options outside the value tables, invocations whose program is
/// unknown, and redirect / process-substitution spellings. Every non-allow
/// row here was allowed on prodfix/integration (a89e14af).
@Suite("Gate bypass follow-up")
struct GateBypassFollowupTests {
    // MARK: Item 1: config from the environment, includes, program keys

    @Test(
        "git config the command line does not show denies as unverified",
        arguments: [
            "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.z GIT_CONFIG_VALUE_0='reset --hard' git z",
            #"env GIT_CONFIG_PARAMETERS="'alias.z=reset --hard'" git z"#,
            "export GIT_CONFIG_GLOBAL=/tmp/evil.cfg; git status",
            "GIT_CONFIG=/tmp/evil.cfg git status",
            "GIT_DIR=/tmp/other/.git git status",
            "GIT_SSH_COMMAND='rm -rf ~' git fetch",
            "bash -c 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.z GIT_CONFIG_VALUE_0=x git z'",
            "git -c include.path=/tmp/evil.cfg status",
            "git -c includeIf.onbranch:main.path=/tmp/x status",
            "git config include.path /tmp/evil.cfg",
            "git config --global core.fsmonitor ./hook.sh",
            "git -c core.sshCommand=./x fetch",
            "git -c diff.external=./x diff",
            "git config core.hooksPath /tmp/hooks",
            "git -c credential.helper=./x fetch",
            "git -c filter.x.smudge=./x checkout .",
            "git --config-env=core.pager=PAGER log",
            "git -c core.pager=./x log",
        ]
    )
    func hiddenConfigDenies(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            guard case .deny(let deny) = result.decision else {
                Issue.record("\(command): \(describeDecision(result))")
                continue
            }
            #expect(deny.ruleID.rawValue == unverifiedAlias, "\(command)")
        }
    }

    @Test(
        "visible or inert git config stays allowed",
        arguments: [
            #"git config user.name "Dev""#,
            "git config --get core.pager",
            "git config --unset core.hooksPath",
            "git -c color.ui=always status",
            #"git commit -m "document GIT_DIR=foo usage""#,
            "GIT_TRACE=1 git status",
            "GIT_PAGER=cat git log -3",
            "GIT_EDITOR=true git commit --amend",
            "git -c core.pager=cat log -3",
            "git -c core.editor=true commit --amend",
        ]
    )
    func visibleConfigAllows(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision == .allow, "\(command): \(describeDecision(result))")
        }
    }

    // MARK: Item 2: wrapper options outside the value tables

    @Test(
        "an env or sudo option value is never taken for the command",
        arguments: [
            "env --u echo mkfs.ext4 /dev/sdb1",
            "env --un echo rm -rf src",
            "env --ch echo rm -rf src",
            "env --a echo rm -rf src",
            "env -a echo rm -rf src",
            "env -iu echo rm -rf src",
            "env -0a echo diskutil eraseDisk APFS X disk4",
            "env --bogus echo rm -rf src",
            "env --i echo rm -rf src",
            "sudo -a echo mkfs.ext4 /dev/sdb1",
        ]
    )
    func wrapperOptionValueDoesNotMask(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "ordinary env and sudo forms stay allowed",
        arguments: [
            "env -i PATH=/usr/bin ls",
            "env --ignore-environment ls",
            "env --chdir=src ls",
            "env -u FOO ls",
            "env --unset=FOO ls",
            "env --uns FOO ls",
            "env FOO=bar npm test",
            "sudo -u root ls",
        ]
    )
    func ordinaryWrapperAllows(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision == .allow, "\(command): \(describeDecision(result))")
        }
    }

    // MARK: Item 3: unknown program or git subcommand

    @Test(
        "an invocation whose program or git subcommand is unknown asks",
        arguments: [
            #"g(){ git "$@"; }; g reset --hard"#,
            #"function g { git "$@"; }; g reset --hard"#,
            #"f() { rm -rf "$@"; }; f src"#,
            "G=git; $G reset --hard",
            #""$GIT" reset --hard"#,
            #"eval "$CMD""#,
            "source ./helpers.sh && g reset --hard",
            ". ./helpers.sh; g reset --hard",
            // After a source, git itself may be a function or run under
            // exported config the guard cannot see.
            "source ./helpers.sh && git status",
            ". ./env.sh; sudo git log",
            // A backslash stops alias lookup, not the builtin.
            "\\alias g=git; g st",
            "\\source ./helpers.sh && g reset --hard",
            "git st",
            "git z",
            "git $SUB --hard",
            "git flow feature finish x",
        ]
    )
    func unresolvedInvocationAsks(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            // A body whose own text already denies may deny instead.
            #expect(
                result.decision == .indeterminate(.unresolvedInvocation) || isDenied(result),
                "\(command): \(describeDecision(result))"
            )
        }
    }

    @Test(
        "known programs and git subcommands stay allowed",
        arguments: [
            "git status",
            "git lfs pull",
            "git help log",
            "git --version",
            "git -C repo log --oneline",
            "$HOME/bin/tool --help",
            "source .venv/bin/activate",
            #"eval "git status""#,
            "ls $(pwd)",
            "x=$(git rev-parse HEAD)",
            "g() { :; }",
            // A function that reads no arguments runs only its visible body.
            "x() { echo hi; }; x",
            "foo(){ bar | baz; }; foo",
            // A sourced file's definitions can do no more than the file did
            // when sourced; only git and git-shaped calls stay floored.
            "source .venv/bin/activate && pytest",
            "source .venv/bin/activate && python -m pytest -x",
            "source venv/bin/activate && pip install -r requirements.txt",
            ". ~/.nvm/nvm.sh && nvm use 20",
            "source ~/.cargo/env; cargo test",
        ]
    )
    func resolvedInvocationAllows(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision == .allow, "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "an unknown program with an inert body asks rather than denies",
        arguments: [#"g(){ git "$@"; }; g st"#, "git st", #"eval "$CMD""#, #"eval "$(direnv hook bash)""#]
    )
    func unresolvedInvocationIsIndeterminate(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision == .indeterminate(.unresolvedInvocation), "\(command): \(describeDecision(result))")
        }
    }

    /// A file-writing heredoc body is data: it is not alias-resolved, so a
    /// long body does not exhaust the expansion bound (which denies) and a
    /// script's own `main "$@"` does not read as a function call (which asks).
    @Test func heredocBodiesAreNotAliasResolved() throws {
        let harness = try StressHarness.dayOne()
        let long = (0..<300).map { "print(\($0))" }.joined(separator: "\n")
        let script = """
        main() {
          echo "building $1"
        }
        main "$@"
        """
        for command in [
            "cat > big.py <<'EOF'\n\(long)\nEOF",
            "cat > build.sh <<'EOF'\n\(script)\nEOF",
            "cat > notes.md <<'EOF'\ng() { git \"$@\"; }\ng reset --hard\nEOF",
        ] {
            for result in [harness.pin(command), harness.door(command)] {
                #expect(result.decision == .allow, "\(command.prefix(40)): \(describeDecision(result))")
            }
        }
    }

    /// An executing heredoc is still read: its body runs.
    @Test func executingHeredocBodyIsStillResolved() throws {
        let harness = try StressHarness.dayOne()
        let command = "bash <<'EOF'\ng() { git \"$@\"; }\ng reset --hard\nEOF"
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision != .allow, "\(describeDecision(result))")
        }
    }

    @Test func unresolvedInvocationNeedsCoreGit() throws {
        let harness = try StressHarness.dayOne()
        let result = harness.pin("git st", enabled: [.coreFilesystem])
        #expect(result.decision == .allow, "\(describeDecision(result))")
    }

    // MARK: Item 6: redirect spellings and process substitution

    @Test(
        "fd-prefixed and read-write input redirects still name the secret",
        arguments: ["cat 0<.env", "true 0<.env", "cat <>.env", "wc -l 3<.env"]
    )
    func fdRedirectIsASecretRead(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    @Test(
        "a process substitution is judged as its own command",
        arguments: [
            "git checkout -b feat <(git reset --hard)",
            "git checkout -b feat >(git clean -fdx)",
        ]
    )
    func processSubstitutionIsJudged(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    @Test func ordinaryProcessSubstitutionAllows() throws {
        let harness = try StressHarness.dayOne()
        let command = "diff <(ls a) <(ls b)"
        #expect(harness.door(command).decision == .allow, "\(describeDecision(harness.door(command)))")
    }
}
