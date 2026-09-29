import Testing
import RVDomain
@testable import RVEngine

// MARK: - Single recursive unwrap over Argv (T2 seam)

@Suite struct ShellPipelineUnwrapTests {
    @Test func budget_defaults_matchLegacyLimits() {
        #expect(UnwrapBudget.default.maxDepth == 8)
        #expect(UnwrapBudget.default.maxBytes == 4_096)
        #expect(UnwrapLimits.maxDepth == UnwrapBudget.default.maxDepth)
        #expect(UnwrapLimits.maxBytes == UnwrapBudget.default.maxBytes)
        #expect(UnwrapBudget() == .default)
    }

    @Test func unwrap_recursesOverArgvThroughLayers() {
        let outcome = ShellPipeline.unwrap(
            "sudo timeout 5 bash -c 'git status'",
            workingDirectory: nil,
            budget: .default,
            depth: 0,
            layers: []
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git status")
        #expect(unwrapped.layers == [.sudo, .timeout, .bash])
    }

    @Test func unwrap_budgetDepth_isLimited() {
        let outcome = ShellPipeline.unwrap(
            "sudo env bash -c 'git reset --hard'",
            workingDirectory: nil,
            budget: UnwrapBudget(maxDepth: 2, maxBytes: 4_096),
            depth: 0,
            layers: []
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("expected limited, got \(outcome)")
            return
        }
        #expect(layers == [.sudo, .env, .bash])
    }

    @Test func unwrap_budgetDepth_exactBoundary_completes() {
        // Cutoff is depth + 1 > maxDepth, so N layers with maxDepth N completes.
        let outcome = ShellPipeline.unwrap(
            "sudo env git status",
            workingDirectory: nil,
            budget: UnwrapBudget(maxDepth: 2, maxBytes: 4_096),
            depth: 0,
            layers: []
        )
        #expect(
            outcome
                == .complete(
                    UnwrappedCommand(
                        command: ShellCommand(rawValue: "git status"),
                        layers: [.sudo, .env]
                    )
                )
        )
    }

    @Test func unwrap_budgetBytes_exactBoundary_completes() {
        // Cutoff is inner.utf8.count > maxBytes, so == maxBytes completes.
        let payload = String(repeating: "x", count: 50)
        let outcome = ShellPipeline.unwrap(
            "bash -c '\(payload)'",
            workingDirectory: nil,
            budget: UnwrapBudget(maxDepth: 8, maxBytes: 50),
            depth: 0,
            layers: []
        )
        #expect(
            outcome
                == .complete(
                    UnwrappedCommand(
                        command: ShellCommand(rawValue: payload),
                        layers: [.bash]
                    )
                )
        )
    }

    @Test func unwrap_budgetBytes_oneOver_isLimited() {
        let payload = String(repeating: "x", count: 51)
        let outcome = ShellPipeline.unwrap(
            "bash -c '\(payload)'",
            workingDirectory: nil,
            budget: UnwrapBudget(maxDepth: 8, maxBytes: 50),
            depth: 0,
            layers: []
        )
        #expect(outcome == .limited(layers: [.bash]))
    }

    @Test func unwrap_workingDirectory_threadsThroughNext() {
        let outcome = ShellPipeline.unwrap(
            "env --chdir=/tmp sudo git status",
            workingDirectory: nil,
            budget: .default,
            depth: 0,
            layers: []
        )
        guard case .complete(let unwrapped) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(unwrapped.command.rawValue == "git status")
        #expect(unwrapped.layers == [.env, .sudo])
        #expect(unwrapped.workingDirectory == WorkingDirectory(validating: "/tmp"))
    }

    @Test func unwrap_budgetBytes_isLimited() {
        let payload = String(repeating: "x", count: 200)
        let outcome = ShellPipeline.unwrap(
            "bash -c '\(payload)'",
            workingDirectory: nil,
            budget: UnwrapBudget(maxDepth: 8, maxBytes: 50),
            depth: 0,
            layers: []
        )
        guard case .limited(let layers) = outcome else {
            Issue.record("expected limited, got \(outcome)")
            return
        }
        #expect(layers == [.bash])
    }

    @Test func unwrap_goldenCorpus_pinsBehavior() {
        let corpus: [(raw: String, outcome: UnwrapOutcome)] = [
            ("sudo git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.sudo]))),
            ("env FOO=1 git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.env]))),
            ("command git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.command]))),
            ("timeout 5 git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.timeout]))),
            ("nice -n 5 git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.nice]))),
            ("mise exec -- git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.mise]))),
            ("ssh host git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.ssh]))),
            ("bash -c 'git status'", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.bash]))),
            (#"python -c "os.system('git status')""#, .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.python]))),
            ("echo 'git status' | bash", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: [.bash]))),
            ("git status", .complete(UnwrappedCommand(command: ShellCommand(rawValue: "git status"), layers: []))),
            ("bash -c git status", .limited(layers: [.bash])),
        ]
        for entry in corpus {
            // Both the public adapter and the recursion must match the golden,
            // which pins behavior and adapter wiring at once.
            #expect(
                unwrapCommand(ShellCommand(rawValue: entry.raw)) == entry.outcome,
                "adapter drift for \(entry.raw)"
            )
            #expect(
                ShellPipeline.unwrap(
                    entry.raw,
                    workingDirectory: nil,
                    budget: .default,
                    depth: 0,
                    layers: []
                ) == entry.outcome,
                "recursion drift for \(entry.raw)"
            )
        }
    }

    @Test(arguments: peelCases)
    fileprivate func peel_dispatchesOneLayerOnArgvProgram(cased: PeelCase) {
        let tokens = ShellPipeline.tokenize(cased.raw)
        let outcome = ShellPipeline.peel(
            text: cased.raw,
            tokens: tokens,
            argv: Argv(tokens: tokens),
            workingDirectory: nil
        )
        #expect(outcome == .next(cased.inner, cased.kind, nil))
    }

    @Test func peel_surfaceCommands_stayNotWrapper() {
        for raw in ["git status", "echo 'rm -rf /'", "mise install", "bash script.sh"] {
            let tokens = ShellPipeline.tokenize(raw)
            let outcome = ShellPipeline.peel(
                text: raw,
                tokens: tokens,
                argv: Argv(tokens: tokens),
                workingDirectory: nil
            )
            #expect(outcome == .notWrapper, "surface kept for \(raw)")
        }
    }

    @Test func peel_failClosedPayloads_areLimited() {
        let cases: [(raw: String, kind: WrapperKind)] = [
            ("bash -c git status", .bash),
            (raw: "bash -c '$CMD'", kind: .bash),
            (#"python3 -c "$CMD""#, .python),
        ]
        for cased in cases {
            let tokens = ShellPipeline.tokenize(cased.raw)
            let outcome = ShellPipeline.peel(
                text: cased.raw,
                tokens: tokens,
                argv: Argv(tokens: tokens),
                workingDirectory: nil
            )
            #expect(outcome == .limited(cased.kind), "limited for \(cased.raw)")
        }
    }

    @Test func peel_leadingNewline_staysNotWrapper() {
        let tokens = [ShellPipeline.Token(lexeme: "\n", wasQuoted: false)]
        let outcome = ShellPipeline.peel(
            text: "\n",
            tokens: tokens,
            argv: Argv(tokens: tokens),
            workingDirectory: nil
        )
        #expect(outcome == .notWrapper)
        #expect(Argv(tokens: tokens) == nil)
    }

    @Test func publicAdapter_absoluteBehavior() {
        let nested = unwrapCommand(ShellCommand(rawValue: "sudo ssh host git status"))
        guard case .complete(let unwrapped) = nested else {
            Issue.record("expected complete, got \(nested)")
            return
        }
        #expect(unwrapped.command.rawValue == "git status")
        #expect(unwrapped.layers == [.sudo, .ssh])

        let sink = unwrapCommand(ShellCommand(rawValue: "echo 'git status' | bash"))
        guard case .complete(let sunk) = sink else {
            Issue.record("expected complete, got \(sink)")
            return
        }
        #expect(sunk.command.rawValue == "git status")
        #expect(sunk.layers == [.bash])

        #expect(
            unwrapCommand(ShellCommand(rawValue: "ssh host 'echo $HOME'"))
                == .limited(layers: [.ssh])
        )
        #expect(
            unwrapCommand(ShellCommand(rawValue: "sudo git status"), maxDepth: 0)
                == .limited(layers: [.sudo])
        )
        #expect(
            unwrapCommand(ShellCommand(rawValue: "mise exec git status"))
                == .limited(layers: [.mise])
        )
    }

    @Test func executingSink_peelsThroughSingleDispatch() {
        let tokens = ShellPipeline.tokenize("echo 'git status' | bash")
        let outcome = ShellPipeline.peel(
            text: "echo 'git status' | bash",
            tokens: tokens,
            argv: Argv(tokens: tokens),
            workingDirectory: nil
        )
        #expect(outcome == .next("git status", .bash, nil))
    }
}

private struct PeelCase: Sendable {
    var raw: String
    var inner: String
    var kind: WrapperKind
}

private let peelCases: [PeelCase] = [
    PeelCase(raw: "sudo git status", inner: "git status", kind: .sudo),
    PeelCase(raw: "env FOO=1 git status", inner: "git status", kind: .env),
    PeelCase(raw: "command git status", inner: "git status", kind: .command),
    PeelCase(raw: "timeout 5 git status", inner: "git status", kind: .timeout),
    PeelCase(raw: "nice -n 5 git status", inner: "git status", kind: .nice),
    PeelCase(raw: "mise exec -- git status", inner: "git status", kind: .mise),
    PeelCase(raw: "ssh host git status", inner: "git status", kind: .ssh),
    PeelCase(raw: "bash -c 'git status'", inner: "git status", kind: .bash),
    PeelCase(raw: "sh -c 'git status'", inner: "git status", kind: .sh),
    PeelCase(raw: "zsh -c 'git status'", inner: "git status", kind: .zsh),
    PeelCase(
        raw: #"python -c "os.system('git status')""#,
        inner: "git status",
        kind: .python
    ),
    PeelCase(
        raw: #"node -e "child_process.execSync('git status')""#,
        inner: "git status",
        kind: .node
    ),
    PeelCase(
        raw: #"ruby -e "system('git status')""#,
        inner: "git status",
        kind: .ruby
    ),
    PeelCase(raw: "timeout --preserve-status 5 git status", inner: "git status", kind: .timeout),
    PeelCase(raw: "nice --adjustment 5 git status", inner: "git status", kind: .nice),
    PeelCase(raw: "ssh -p 2222 host git status", inner: "git status", kind: .ssh),
    PeelCase(raw: "mise exec -c 'git status'", inner: "git status", kind: .mise),
    PeelCase(raw: "command -p git status", inner: "git status", kind: .command),
    PeelCase(raw: "/usr/bin/sudo git status", inner: "git status", kind: .sudo),
    PeelCase(raw: "SUDO git status", inner: "git status", kind: .sudo),
]
