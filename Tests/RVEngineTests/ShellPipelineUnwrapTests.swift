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
        #expect(layers.contains(.bash))
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

    @Test func unwrap_matchesPublicAdapter() {
        let corpus = [
            "sudo git status",
            "env FOO=1 git status",
            "command git status",
            "timeout 5 git status",
            "nice -n 5 git status",
            "mise exec -- git status",
            "ssh host git status",
            "bash -c 'git status'",
            #"python -c "os.system('git status')""#,
            "echo 'git status' | bash",
            "git status",
            "bash -c git status",
        ]
        for raw in corpus {
            let expected = unwrapCommand(ShellCommand(rawValue: raw))
            let actual = ShellPipeline.unwrap(
                raw,
                workingDirectory: nil,
                budget: .default,
                depth: 0,
                layers: []
            )
            #expect(actual == expected, "mismatch for \(raw)")
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
        let tokens = [Token(lexeme: "\n", wasQuoted: false)]
        let outcome = ShellPipeline.peel(
            text: "\n",
            tokens: tokens,
            argv: Argv(tokens: tokens),
            workingDirectory: nil
        )
        #expect(outcome == .notWrapper)
        #expect(Argv(tokens: tokens) == nil)
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
]
