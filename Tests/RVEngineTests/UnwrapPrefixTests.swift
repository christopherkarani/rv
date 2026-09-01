import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap prefix wrappers")
struct UnwrapPrefixTests {
    @Test func timeoutDuration_extractsInnerCommand() {
        expectComplete(
            "timeout 1 git reset --hard",
            inner: "git reset --hard",
            layers: [.timeout]
        )
    }

    @Test func nice_extractsInnerCommand() {
        expectComplete(
            "nice git reset --hard",
            inner: "git reset --hard",
            layers: [.nice]
        )
    }

    @Test func miseExecDashC_extractsInnerCommand() {
        expectComplete(
            "mise exec -c 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.mise]
        )
    }

    @Test func sshQuotedPayload_extractsRemoteCommand() {
        expectComplete(
            "ssh example 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.ssh]
        )
    }

    @Test func sshUnknownOption_doesNotExtract() {
        let raw = "ssh -Z example 'git reset --hard'"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("unknown ssh option must leave the surface, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
    }

    @Test func miseUnquotedDashC_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "mise exec -c git reset --hard"))
        guard case .limited(let layers) = outcome else {
            Issue.record("unquoted mise -c must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.mise])
    }

    @Test func timeoutUnknownOption_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "timeout --bogus 1 git reset --hard")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("unknown timeout option must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.timeout])
    }

    @Test func timeoutMissingCommand_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "timeout 1"))
        guard case .limited(let layers) = outcome else {
            Issue.record("timeout without a command must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.timeout])
    }

    @Test func niceUnknownOption_isLimited() {
        let outcome = unwrapCommand(
            ShellCommand(rawValue: "nice --bogus git reset --hard")
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("unknown nice option must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.nice])
    }

    @Test func niceAdjustment_extractsInnerCommand() {
        expectComplete(
            "nice -n 10 git reset --hard",
            inner: "git reset --hard",
            layers: [.nice]
        )
        expectComplete(
            "nice --adjustment=5 git reset --hard",
            inner: "git reset --hard",
            layers: [.nice]
        )
    }

    @Test func timeoutModeledOptions_extractsInnerCommand() {
        expectComplete(
            "timeout --foreground --verbose -k 2s --signal=TERM 1 git reset --hard",
            inner: "git reset --hard",
            layers: [.timeout]
        )
    }

    @Test func miseExecDashDash_extractsInnerCommand() {
        expectComplete(
            "mise exec -- git reset --hard",
            inner: "git reset --hard",
            layers: [.mise]
        )
    }

    @Test func miseUnquotedSubstitutionDashC_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "mise exec -c '$CMD'"))
        guard case .limited(let layers) = outcome else {
            Issue.record("mise -c substitution must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.mise])
    }

    @Test func sshModeledOptions_extractsRemoteCommand() {
        expectComplete(
            "ssh -p 22 -i key -l user -o StrictHostKeyChecking=no -F cfg -J jump --port=2222 example 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.ssh]
        )
    }

    @Test func sshUnquotedTrailingTokens_extract() {
        expectComplete(
            "ssh example git reset --hard",
            inner: "git reset --hard",
            layers: [.ssh]
        )
    }

    @Test func sshQuotedSubstitution_isLimited() {
        let outcome = unwrapCommand(ShellCommand(rawValue: "ssh example 'echo $HOME'"))
        guard case .limited(let layers) = outcome else {
            Issue.record("quoted ssh payload with $ must be limited, got \(outcome)")
            return
        }
        #expect(layers == [.ssh])
    }

    @Test func sshDestinationAlone_isNotACommand() {
        let raw = "ssh example"
        let outcome = unwrapCommand(ShellCommand(rawValue: raw))
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("ssh destination must not be treated as a command, got \(outcome)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == raw)
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
