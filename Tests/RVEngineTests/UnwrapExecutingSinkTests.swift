import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap executing sinks")
struct UnwrapExecutingSinkTests {
    @Test func echoPipeBashNorc_extractsInnerCommand() {
        expectComplete(
            "echo 'git reset --hard' | bash --norc",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func echoPipeBash_extractsRm() {
        expectComplete(
            "echo 'rm -rf ~' | bash",
            inner: "rm -rf ~",
            layers: [.bash]
        )
    }

    @Test func catHeredocPipeBash_extractsBody() {
        let raw = """
            cat <<'EOF' | bash
            git reset --hard
            EOF
            """
        expectComplete(raw, inner: "git reset --hard", layers: [.bash])
    }

    @Test func bashDevStdinHeredoc_extractsBody() {
        let raw = """
            bash /dev/stdin <<'EOF'
            git reset --hard
            EOF
            """
        expectComplete(raw, inner: "git reset --hard", layers: [.bash])
    }

    @Test func bashInitFileProcessSub_extractsEchoPayload() {
        expectComplete(
            "bash --init-file <(echo 'git reset --hard')",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func echoQuotedReset_withoutPipe_isNotUnwrapped() {
        let raw = "echo 'git reset --hard'"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("echo without a pipe must stay complete, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func gitStatus_isNotUnwrapped() {
        let raw = "git status"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("git status must stay complete, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func catHeredocPipeGrep_isNotUnwrapped() {
        let raw = """
            cat <<'EOF' | grep -c reset
            git reset --hard
            EOF
            """
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("grep is a data consumer, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func echoPipeTee_isNotUnwrapped() {
        let raw = "echo 'git reset --hard' | tee"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("tee is a data consumer, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func echoPipeBashThenTee_extractsInnerCommand() {
        expectComplete(
            "echo 'git reset --hard' | bash | tee",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func echoPipeWc_isNotUnwrapped() {
        let raw = "echo 'git reset --hard' | wc"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("wc is a data consumer, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func bashUnknownFlagAsStdinConsumer_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "echo 'git reset --hard' | bash --unknown-flag")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("unmodeled executing-sink option must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func catFilePipeBash_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "cat somefile | bash"))
        guard case .limited(let layers) = outcome else {
            Issue.record("cat file | bash cannot read the file, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func bashInitFileProcessSubCat_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "bash --init-file <(cat somefile)")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("non-echo process-sub must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func echoPipeBashDashC_extractsPayload() {
        expectComplete(
            "echo ignored | bash -c 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func echoPipeBashDashS_extractsInnerCommand() {
        expectComplete(
            "echo 'git reset --hard' | bash -s",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func echoAnsiCPipeBash_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "echo $'git reset --hard' | bash")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record(
                "ANSI-C echo producer must be limited, not complete inner, got \(outcome)"
            )
            return
        }
        #expect(layers == [.bash])
    }

    @Test func bashDashCAnsiC_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "bash -c $'git reset --hard'")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("ANSI-C bash -c must stay limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func heredocToFile_isNotUnwrapped() {
        let raw = """
            cat > dest <<'EOF'
            git reset --hard
            EOF
            """
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("heredoc-to-file must stay complete, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func bashHeredocWithoutPipe_extractsBody() {
        let raw = """
            bash <<'EOF'
            git reset --hard
            EOF
            """
        expectComplete(raw, inner: "git reset --hard", layers: [.bash])
    }

    @Test func bashDashHeredoc_stripsTabs() {
        let raw = "bash <<- EOF\n\tgit status\nEOF"
        expectComplete(raw, inner: "git status", layers: [.bash])
        expectComplete(
            "bash <<- 'EOF'\n\tgit reset --hard\nEOF",
            inner: "git reset --hard",
            layers: [.bash]
        )
    }

    @Test func bashQuotedHeredoc_extractsBody() {
        let raw = """
            bash <<"EOF"
            git status
            EOF
            """
        expectComplete(raw, inner: "git status", layers: [.bash])
    }

    @Test func hereString_isNotUnwrapped() {
        let raw = "bash <<<'git reset --hard'"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("here-string must stay complete, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
    }

    @Test func processSubAndStdinOperands() {
        expectComplete(
            "bash <(echo 'git reset --hard')",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | bash -",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | python /dev/stdin",
            inner: "git reset --hard",
            layers: [.python]
        )
        expectComplete(
            "echo 'git reset --hard' | ruby /dev/fd/0",
            inner: "git reset --hard",
            layers: [.ruby]
        )
        expectComplete(
            "echo 'git reset --hard' | /bin/bash --norc --noprofile -s",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | bash --init-file=/tmp/rc",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | python3 -u",
            inner: "git reset --hard",
            layers: [.python]
        )
        expectComplete(
            "echo 'git reset --hard' | nodejs --no-warnings",
            inner: "git reset --hard",
            layers: [.node]
        )
        expectComplete(
            "echo 'git reset --hard' | ruby -v",
            inner: "git reset --hard",
            layers: [.ruby]
        )
        expectComplete(
            "echo 'git reset --hard' | bash --",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | grep reset | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | cat | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "printf '%s' 'git reset --hard' | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "printf 'git reset --hard' | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo -ne 'git reset --hard' | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo -- 'git reset --hard' | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo ignored | bash --command 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo ignored | zsh -c 'git status'",
            inner: "git status",
            layers: [.zsh]
        )
        expectComplete(
            "echo ignored | sh -c 'git status'",
            inner: "git status",
            layers: [.sh]
        )
        expectComplete(
            "echo ignored | bash --command='git status'",
            inner: "git status",
            layers: [.bash]
        )
        expectComplete(
            "echo ignored | bash -o errexit -c 'git status'",
            inner: "git status",
            layers: [.bash]
        )
        expectComplete(
            "echo ignored | bash -xc 'git status'",
            inner: "git status",
            layers: [.bash]
        )
        expectComplete(
            "echo -E 'git reset --hard' | bash",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectSinkTouched("bash <(echo `inner` 'git reset --hard')", .bash)
        expectSinkTouched("bash <(echo <(true) 'git reset --hard')", .bash)
        expectSinkTouched("bash <(echo (x) 'git reset --hard')", .bash)
        expectComplete(
            "echo 'git reset --hard' | bash -eux",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "echo 'git reset --hard' | python -W default",
            inner: "git reset --hard",
            layers: [.python]
        )
        expectComplete(
            "echo 'git reset --hard' | node --input-type=commonjs",
            inner: "git reset --hard",
            layers: [.node]
        )
        expectComplete(
            "echo 'git reset --hard' | ruby -r json -W2",
            inner: "git reset --hard",
            layers: [.ruby]
        )
        expectComplete(
            "echo 'git reset --hard' | bash --init-file /tmp/rc",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "bash --init-file <(printf '%s' 'git status')",
            inner: "git status",
            layers: [.bash]
        )
    }

    @Test func executingSinkLimitedEdges() {
        expectLimited("echo 'git reset --hard' | python script.py", .python)
        expectLimited("echo 'git reset --hard' | python -X", .python)
        expectLimited("echo 'git reset --hard' | node --title", .node)
        expectLimited("echo 'git reset --hard' | ruby -I", .ruby)
        expectLimited("echo 'git reset --hard' | bash --rcfile", .bash)
        expectLimited("echo 'git reset --hard' | bash -- script.sh", .bash)
        expectLimited("echo $FOO | bash", .bash)
        expectLimited("echo 'git reset --hard' | sed s/a/b/ | bash", .bash)
        expectLimited("echo ignored | python -c 'print(1)'", .python)
        expectLimited("echo ignored | ruby -e'print 1'", .ruby)
        expectLimited("echo ignored | node --eval=1", .node)
        expectLimited("echo ignored | node --print=1", .node)
        expectLimited("echo ignored | bash -c", .bash)
        expectLimited("echo ignored | bash --command", .bash)
        expectLimited("echo ignored | bash -o", .bash)
        #expect(peelExecutingSink("", workingDirectory: nil) == nil)
        #expect(peelExecutingSink("   ", workingDirectory: nil) == nil)
    }

    @Test func dataConsumersStayOnTheSurface() {
        for raw in [
            "echo 'git reset --hard' | rg reset",
            "echo 'git reset --hard' | ripgrep reset",
            "echo 'git reset --hard' | head",
            "echo 'git reset --hard' | tail",
            "echo 'git reset --hard' | less",
            "echo 'git reset --hard' | more",
            "echo 'git reset --hard' | sort",
            "echo 'git reset --hard' | uniq",
        ] {
            let outcome = unwrapCommand(ShellCommand(rawValue: raw))
            guard case .complete(let unwrapped) = outcome else {
                Issue.record("data consumer must stay complete for \(raw), got \(outcome)")
                continue
            }
            #expect(unwrapped.layers.isEmpty, Comment(rawValue: raw))
        }
    }

    @Test func quotedAndProcessSubPipes() {
        expectComplete(
            "echo 'a | b' | bash",
            inner: "a | b",
            layers: [.bash]
        )
        let orElse = unwrapCommand(ShellCommand(rawValue: "echo a || bash"))
        guard case .complete(let unwrapped) = orElse else {
            Issue.record("|| is not a pipe sink, got \(orElse)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        let unclosed = unwrapCommand(ShellCommand(rawValue: "bash <(echo cmd"))
        guard case .complete(let left) = unclosed else {
            Issue.record("unclosed process-sub must stay complete, got \(unclosed)")
            return
        }
        #expect(left.layers.isEmpty)
        expectLimited("echo `a | b` | bash", .bash)
        let heredocTick = """
            bash `true` <<'EOF'
            git status
            EOF
            """
        expectComplete(heredocTick, inner: "git status", layers: [.bash])
        let incomplete = unwrapCommand(ShellCommand(rawValue: "bash <<EOF"))
        guard case .complete(let incompleteLeft) = incomplete else {
            Issue.record("header-only heredoc must stay complete, got \(incomplete)")
            return
        }
        #expect(incompleteLeft.layers.isEmpty)
        expectComplete("echo (foo|bar) | bash", inner: "(foo|bar)", layers: [.bash])
    }
}

private func expectSinkTouched(_ raw: String, _ kind: WrapperKind) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    switch outcome {
    case .complete(let unwrapped):
        #expect(unwrapped.layers.contains(kind), Comment(rawValue: raw))
    case .limited(let layers):
        #expect(layers.contains(kind), Comment(rawValue: raw))
    }
}

private func expectLimited(_ raw: String, _ kind: WrapperKind) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .limited(let layers) = outcome else {
        Issue.record("expected limited unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(layers.contains(kind))
}

private func expectComplete(_ raw: String, inner: String, layers: [WrapperKind]) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected complete unwrap of \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.command.rawValue == inner)
    #expect(unwrapped.layers == layers)
}
