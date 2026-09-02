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
