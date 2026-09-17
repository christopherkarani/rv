import Testing
import RVDomain
@testable import RVEngine

@Suite("Unwrap adversarial peel")
struct UnwrapAdversarialTests {
    @Test func emptyAndLeadingBackslash() {
        expectComplete("   ", inner: "", layers: [])
        expectComplete("\\git reset --hard", inner: "git reset --hard", layers: [])
        expectComplete("\\env FOO=bar git status", inner: "git status", layers: [.env])
        let bang = unwrapCommand(ShellCommand(rawValue: "\\!git status"))
        guard case .complete(let unwrapped) = bang else {
            Issue.record("non-ident backslash must stay complete, got \(bang)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == "\\!git status")
    }

    @Test func timeoutOptionSoup() {
        expectComplete(
            "timeout --foreground --preserve-status -v --kill-after 2 --signal KILL 10s git reset --hard",
            inner: "git reset --hard",
            layers: [.timeout]
        )
        expectComplete(
            "timeout --kill-after=2s --signal=TERM -- 1.5 /usr/bin/git status",
            inner: "/usr/bin/git status",
            layers: [.timeout]
        )
        expectComplete(
            "timeout 2m git status",
            inner: "git status",
            layers: [.timeout]
        )
        expectComplete(
            "timeout 2h git status",
            inner: "git status",
            layers: [.timeout]
        )
        expectComplete(
            "timeout 2d git status",
            inner: "git status",
            layers: [.timeout]
        )
        expectLimited("timeout --kill-after", .timeout)
        expectLimited("timeout --signal", .timeout)
        expectLimited("timeout -k", .timeout)
        expectLimited("timeout 1x git status", .timeout)
        expectLimited("timeout .5 git status", .timeout)
        expectLimited("timeout", .timeout)
        expectLimited("timeout --", .timeout)
        #expect(
            peelTimeout(
                [
                    CommandToken(decoded: "timeout", wasQuoted: false),
                    CommandToken(decoded: "", wasQuoted: false),
                    CommandToken(decoded: "git", wasQuoted: false),
                ],
                workingDirectory: nil
            ) == .limited(.timeout)
        )
    }

    @Test func niceOptionSoup() {
        expectComplete(
            "nice --adjustment 5 git reset --hard",
            inner: "git reset --hard",
            layers: [.nice]
        )
        expectComplete(
            "nice -n10 git status",
            inner: "git status",
            layers: [.nice]
        )
        expectComplete(
            "nice +10 git status",
            inner: "git status",
            layers: [.nice]
        )
        expectComplete(
            "nice -20 git status",
            inner: "git status",
            layers: [.nice]
        )
        expectComplete(
            "nice -- git status",
            inner: "git status",
            layers: [.nice]
        )
        expectLimited("nice -n", .nice)
        expectLimited("nice --adjustment", .nice)
        expectLimited("nice --adjustment=", .nice)
        expectLimited("nice -n 5", .nice)
        let bare = unwrapCommand(ShellCommand(rawValue: "nice"))
        guard case .complete(let unwrapped) = bare else {
            Issue.record("bare nice is not a wrapper, got \(bare)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        #expect(unwrapped.command.rawValue == "nice")
    }

    @Test func miseOptionSoup() {
        expectComplete(
            "mise x -- git reset --hard",
            inner: "git reset --hard",
            layers: [.mise]
        )
        expectComplete(
            "mise exec --command 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.mise]
        )
        expectLimited("mise exec --command=git", .mise)
        expectLimited("mise exec --", .mise)
        expectLimited("mise exec -c", .mise)
        expectLimited("mise exec --command", .mise)
        expectLimited("mise exec rust@latest", .mise)
        expectLimited("mise exec", .mise)
        let install = unwrapCommand(ShellCommand(rawValue: "mise install"))
        guard case .complete(let unwrapped) = install else {
            Issue.record("mise install is not exec, got \(install)")
            return
        }
        #expect(unwrapped.layers.isEmpty)
        let bare = unwrapCommand(ShellCommand(rawValue: "mise"))
        guard case .complete(let bareUnwrapped) = bare else {
            Issue.record("bare mise is not a wrapper, got \(bare)")
            return
        }
        #expect(bareUnwrapped.layers.isEmpty)
    }

    @Test func sshOptionSoup() {
        expectComplete(
            "ssh -4 -6 -A -C -n -T -v -p 22 -i key -l user -F cfg -J jump --identity=id --login-name=me --port=2222 host 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.ssh]
        )
        expectComplete(
            "ssh -p22 -Tv host git status",
            inner: "git status",
            layers: [.ssh]
        )
        expectComplete(
            "ssh --bind-address=127.0.0.1 -- host git status",
            inner: "git status",
            layers: [.ssh]
        )
        expectComplete(
            "ssh --port 22 host git status",
            inner: "git status",
            layers: [.ssh]
        )
        expectComplete(
            "ssh host git reset --hard",
            inner: "git reset --hard",
            layers: [.ssh]
        )
        expectLimited("ssh host 'echo $HOME'", .ssh)
        expectLimited("ssh host 'echo `date`'", .ssh)
        let unknown = unwrapCommand(ShellCommand(rawValue: "ssh --not-a-flag host git status"))
        guard case .complete(let left) = unknown else {
            Issue.record("unknown ssh long option must leave the surface, got \(unknown)")
            return
        }
        #expect(left.layers.isEmpty)
        let missing = unwrapCommand(ShellCommand(rawValue: "ssh --port"))
        guard case .complete(let missingUnwrapped) = missing else {
            Issue.record("ssh missing long arg must leave the surface, got \(missing)")
            return
        }
        #expect(missingUnwrapped.layers.isEmpty)
        let shortMissing = unwrapCommand(ShellCommand(rawValue: "ssh -p"))
        guard case .complete(let shortUnwrapped) = shortMissing else {
            Issue.record("ssh missing short arg must leave the surface, got \(shortMissing)")
            return
        }
        #expect(shortUnwrapped.layers.isEmpty)
        expectNotPeeled("ssh -v")
        expectNotPeeled("ssh --bogus=1 host git status")
        let dashHost = unwrapCommand(ShellCommand(rawValue: "ssh - host git status"))
        guard case .complete(let dash) = dashHost else {
            Issue.record("ssh lone dash must leave or peel, got \(dashHost)")
            return
        }
        #expect(dash.layers.isEmpty || dash.command.rawValue.contains("git"))
    }

    @Test func sudoEnvCommandPeel() {
        expectComplete(
            "sudo --chdir=/tmp --login --non-interactive git status",
            inner: "git status",
            layers: [.sudo]
        )
        expectComplete(
            "sudo --chdir /var/tmp --user root -n git status",
            inner: "git status",
            layers: [.sudo]
        )
        let chdir = unwrapCommand(
            ShellCommand(rawValue: "sudo --chdir=tmp git status"),
            workingDirectory: WorkingDirectory(validating: "/repo")
        )
        guard case .complete(let moved) = chdir else {
            Issue.record("sudo --chdir should peel, got \(chdir)")
            return
        }
        #expect(moved.command.rawValue == "git status")
        #expect(moved.layers == [.sudo])
        #expect(moved.workingDirectory?.rawValue == "/repo/tmp")
        expectComplete(
            "sudo -D /tmp -- git status",
            inner: "git status",
            layers: [.sudo]
        )
        expectComplete(
            "sudo -u root -g wheel git status",
            inner: "git status",
            layers: [.sudo]
        )
        expectLimited("sudo --chdir", .sudo)
        expectLimited("sudo --user", .sudo)
        expectLimited("sudo --bogus git status", .sudo)
        expectLimited("sudo -D", .sudo)
        expectLimited("sudo -u", .sudo)
        let bare = unwrapCommand(ShellCommand(rawValue: "sudo"))
        guard case .complete(let unwrapped) = bare else {
            Issue.record("bare sudo is not a wrapper, got \(bare)")
            return
        }
        #expect(unwrapped.layers.isEmpty)

        expectComplete(
            "env -i --unset=FOO --chdir=/tmp BAR=1 git status",
            inner: "git status",
            layers: [.env]
        )
        expectComplete(
            "env -u FOO --chdir /tmp git status",
            inner: "git status",
            layers: [.env]
        )
        expectComplete(
            "env - git status",
            inner: "git status",
            layers: [.env]
        )
        expectLimited("env -S git status", .env)
        expectLimited("env --split-string git status", .env)
        expectLimited("env -C", .env)
        expectLimited("env -u", .env)
        let bareEnv = unwrapCommand(ShellCommand(rawValue: "env"))
        guard case .complete(let envOnly) = bareEnv else {
            Issue.record("bare env is not a wrapper, got \(bareEnv)")
            return
        }
        #expect(envOnly.layers.isEmpty)

        expectComplete(
            "command -p git status",
            inner: "git status",
            layers: [.command]
        )
        expectComplete(
            "command -x git status",
            inner: "git status",
            layers: [.command]
        )
        let version = unwrapCommand(ShellCommand(rawValue: "command -v git"))
        guard case .complete(let versioned) = version else {
            Issue.record("command -v is not a wrapper, got \(version)")
            return
        }
        #expect(versioned.layers.isEmpty)
        let which = unwrapCommand(ShellCommand(rawValue: "command -V git"))
        guard case .complete(let whichUnwrapped) = which else {
            Issue.record("command -V is not a wrapper, got \(which)")
            return
        }
        #expect(whichUnwrapped.layers.isEmpty)
        let bareCommand = unwrapCommand(ShellCommand(rawValue: "command"))
        guard case .complete(let commandOnly) = bareCommand else {
            Issue.record("bare command is not a wrapper, got \(bareCommand)")
            return
        }
        #expect(commandOnly.layers.isEmpty)
    }

    @Test func shellDashCOptionSoupAndUnquoted() {
        expectComplete(
            "bash --norc --noprofile -o errexit -c 'git reset --hard'",
            inner: "git reset --hard",
            layers: [.bash]
        )
        expectComplete(
            "bash --command 'git status'",
            inner: "git status",
            layers: [.bash]
        )
        expectLimited("sh --command=git", .sh)
        expectComplete(
            "zsh -xc 'git status'",
            inner: "git status",
            layers: [.zsh]
        )
        expectComplete(
            "bash -x -c 'git status'",
            inner: "git status",
            layers: [.bash]
        )
        expectLimited("bash -c", .bash)
        expectLimited("bash -o", .bash)
        expectLimited("bash -c $CMD", .bash)
        expectLimited("bash -c 'echo $HOME'", .bash)
        expectLimited("bash -c 'echo `date`'", .bash)
        expectLimited("bash -c git reset --hard", .bash)
        let script = unwrapCommand(ShellCommand(rawValue: "bash script.sh"))
        guard case .complete(let left) = script else {
            Issue.record("bash script is not -c, got \(script)")
            return
        }
        #expect(left.layers.isEmpty)
        let dashed = unwrapCommand(ShellCommand(rawValue: "bash -- script.sh"))
        guard case .complete(let dashedLeft) = dashed else {
            Issue.record("bash -- script is not -c, got \(dashed)")
            return
        }
        #expect(dashedLeft.layers.isEmpty)
        let bare = unwrapCommand(ShellCommand(rawValue: "bash"))
        guard case .complete(let bareUnwrapped) = bare else {
            Issue.record("bare bash is not a wrapper, got \(bare)")
            return
        }
        #expect(bareUnwrapped.layers.isEmpty)
    }

    @Test func wrapperDepthNine_isLimited() {
        let nested = "sudo env command timeout 1 nice mise exec -- bash -c 'sh -c '\"'\"'true'\"'\"''"
        let outcome = unwrapCommand(ShellCommand(rawValue: nested))
        switch outcome {
        case .complete(let unwrapped):
            #expect(unwrapped.layers.count >= 7)
        case .limited(let layers):
            #expect(layers.isEmpty == false)
        }
        expectLimited(
            "sudo env command timeout 1 nice mise exec -- bash -c 'sh -c '\"'\"'zsh -c true'\"'\"''",
            nil
        )
    }
}

private func expectNotPeeled(_ raw: String) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .complete(let unwrapped) = outcome else {
        Issue.record("expected surface complete for \(raw), got \(outcome)")
        return
    }
    #expect(unwrapped.layers.isEmpty)
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

private func expectLimited(_ raw: String, _ kind: WrapperKind?) {
    let outcome = unwrapCommand(ShellCommand(rawValue: raw))
    guard case .limited(let layers) = outcome else {
        Issue.record("expected limited unwrap of \(raw), got \(outcome)")
        return
    }
    if let kind {
        #expect(layers.contains(kind))
    } else {
        #expect(layers.isEmpty == false)
    }
}
