import Testing
import RVDomain
@testable import RVEngine

// MARK: - Single entry: matching-view goldens mirror NormalizeTests/CommandPeelTests

@Suite struct ShellPipelineTests {
    @Test func parse_matchingStripsWrappersAndPath() {
        #expect(ShellPipeline.parse("  sudo git reset --hard  ").matching == "git reset --hard")
        #expect(ShellPipeline.parse("env GIT_DIR=.git git reset --hard").matching == "git reset --hard")
        #expect(ShellPipeline.parse("command git reset --hard").matching == "git reset --hard")
        #expect(ShellPipeline.parse("\\git reset --hard").matching == "git reset --hard")
        #expect(ShellPipeline.parse("/usr/bin/git reset --hard").matching == "git reset --hard")
    }

    @Test func parse_matchingKeepsCommandQueryAndQuotes() {
        #expect(ShellPipeline.parse("command -v git").matching == "command -v git")
        #expect(ShellPipeline.parse("command -V git").matching == "command -V git")
        #expect(ShellPipeline.parse("\"git\" reset --hard").matching == "git reset --hard")
        #expect(ShellPipeline.parse("git reset '--hard'").matching == "git reset --hard")
        #expect(ShellPipeline.parse("rm -r'f' /").matching == "rm -rf /")
    }

    @Test func parse_matchingMasksDataRoles() {
        // Exact goldens mirror NormalizeTests: data payloads become spaces,
        // structure survives. Negative `contains` checks alone would pass even
        // if masking silently stopped working.
        let masked16 = String(repeating: " ", count: 16)
        let commit = ShellPipeline.parse("git commit -m \"git reset --hard\"").matching
        #expect(commit.rawValue == "git commit -m " + masked16)
        let attached = ShellPipeline.parse("git commit --message=\"git reset --hard\"").matching
        #expect(attached.rawValue == "git commit --message=" + masked16)
        let search = ShellPipeline.parse("git grep -n \"rm -rf\"").matching
        #expect(search.rawValue == "git grep -n " + String(repeating: " ", count: 6))
    }

    @Test func parse_matchingMasksHeredocWriteBodyKeepsExecutingSink() {
        let write = ShellPipeline.parse(
            "cat > /tmp/note.md << 'EOF'\nSee git reset --hard\nEOF"
        ).matching
        #expect(write.rawValue.contains("reset") == false)
        let executing = ShellPipeline.parse(
            "cat <<'EOF' | bash\ngit reset --hard\nEOF"
        ).matching
        #expect(executing.rawValue.contains("git reset --hard"))
    }

    @Test func parse_matchingSurfacesAnsiCArgv0BeforeStrip() {
        // Mask-before-strip order is load-bearing: `$'sudo'` must surface as
        // a wrapper before the strip loop runs.
        #expect(ShellPipeline.parse("$'sudo' git status").matching == "git status")
    }

    @Test func adapters_delegateToSingleParse() {
        // Both thin adapters must agree with the facade on every input shape,
        // including the empty and budget-limited paths.
        let inputs = [
            "sudo git reset --hard",
            "\"git\" reset --hard",
            "git commit -m \"git reset --hard\"",
            "cat > /tmp/note.md << 'EOF'\nSee git reset --hard\nEOF",
            "cat <<'EOF' | bash\ngit reset --hard\nEOF",
            "$'sudo' git status",
            "sudo --not-a-flag git status",
            "",
            "   ",
        ]
        for input in inputs {
            let parsed = ShellPipeline.parse(input)
            #expect(Normalize.matchingView(of: input) == parsed.matching)
            #expect(
                Normalize.matchingView(of: ShellCommand(rawValue: input)) == parsed.matching
            )
            #expect(CommandPeelCore.matchingView(of: input) == parsed.matching)
            switch CommandPeelCore.peel(ShellCommand(rawValue: input)) {
            case .complete(let matching, let executing, let layers):
                #expect(matching == parsed.matching)
                #expect(parsed.executing == executing)
                #expect(layers == parsed.layers)
            case .limited(let matching, let layers):
                #expect(matching == parsed.matching)
                #expect(parsed.executing == nil)
                #expect(layers == parsed.layers)
            }
        }
    }
}

// MARK: - Single entry: stage outputs and typed errors

@Suite struct ShellPipelineStagesTests {
    @Test func parse_exposesTokensAndSegments() {
        let parsed = ShellPipeline.parse("git status")
        #expect(parsed.tokens.map(\.lexeme) == ["git", "status"])
        #expect(parsed.segments == [Argv(program: "git", args: ["status"])])
        #expect(parsed.error == nil)
    }

    @Test func parse_splitsSegmentsOnNewlines() {
        let parsed = ShellPipeline.parse("echo a\ngit status")
        #expect(parsed.segments.map(\.program) == ["echo", "git"])
        #expect(parsed.segments.map(\.args) == [["a"], ["status"]])
        #expect(parsed.error == nil)
    }

    @Test func parse_emptyInput_reportsEmptyCommand() {
        for input in ["", "   "] {
            let parsed = ShellPipeline.parse(input)
            #expect(parsed.error == .emptyCommand)
            #expect(parsed.segments == [])
            #expect(parsed.tokens == [])
            #expect(parsed.matching == "")
        }
    }

    @Test func parse_newlineOnlyInput_reportsEmptyCommand() {
        // Structural newlines are tokens but carry no command words, so the
        // parse stage still reports `.emptyCommand` with an empty grant key.
        for input in ["\n", "\n\n"] {
            let parsed = ShellPipeline.parse(input)
            #expect(parsed.error == .emptyCommand)
            #expect(parsed.segments == [])
            #expect(parsed.tokens == [Token(lexeme: "\n", wasQuoted: false)])
            #expect(parsed.matching == "")
        }
    }

    @Test func parse_completePeel_exposesExecutingAndLayers() {
        let parsed = ShellPipeline.parse("sudo git reset --hard")
        #expect(parsed.matching == "git reset --hard")
        #expect(parsed.executing?.rawValue == "git reset --hard")
        #expect(parsed.layers == [.sudo])
        #expect(parsed.error == nil)
    }

    @Test func parse_bashDashC_keepsGrantKey() {
        let parsed = ShellPipeline.parse("bash -c 'git reset --hard'")
        #expect(parsed.matching.rawValue.contains("bash"))
        #expect(parsed.executing?.rawValue == "git reset --hard")
        #expect(parsed.layers == [.bash])
        #expect(parsed.error == nil)
    }

    @Test func parse_limitedUnwrap_reportsTypedError() {
        let parsed = ShellPipeline.parse("sudo --not-a-flag git status")
        #expect(parsed.error == .unwrapLimited(layers: [.sudo]))
        #expect(parsed.executing == nil)
        #expect(parsed.layers == [.sudo])
        #expect(parsed.matching.rawValue.contains("sudo"))
    }

    @Test func peelStage_masksHeredocWriteBody() {
        let write = ShellPipeline.peelStage(
            "cat > /tmp/note.md << 'EOF'\nSee git reset --hard\nEOF"
        )
        #expect(write.contains("reset") == false)
        let sink = "cat <<'EOF' | bash\ngit reset --hard\nEOF"
        #expect(ShellPipeline.peelStage(sink) == sink)
        #expect(ShellPipeline.peelStage("   ") == "")
    }

    @Test func unwrapStage_reportsTypedLimitation() {
        let limited = ShellPipeline.unwrapStage("sudo --not-a-flag git status")
        #expect(limited == .failure(.unwrapLimited(layers: [.sudo])))
        guard case .success(let inner) = ShellPipeline.unwrapStage("sudo git reset --hard") else {
            Issue.record("sudo git reset must unwrap completely")
            return
        }
        #expect(inner.command.rawValue == "git reset --hard")
        #expect(inner.layers == [.sudo])
    }

    @Test func parseStage_reportsEmptyCommand() {
        #expect(ShellPipeline.parseStage([]) == .failure(.emptyCommand))
        #expect(
            ShellPipeline.parseStage(ShellPipeline.tokenize("git status"))
                == .success([Argv(program: "git", args: ["status"])])
        )
    }

    @Test func classifyStage_matchesNormalizeGoldens() {
        #expect(ShellPipeline.classifyStage("sudo git reset --hard") == "git reset --hard")
        #expect(ShellPipeline.classifyStage("command -v git") == "command -v git")
        #expect(
            ShellPipeline.classifyStage("git commit -m \"git reset --hard\"").rawValue
                == "git commit -m " + String(repeating: " ", count: 16)
        )
    }

    @Test func roleAwareQuotes_tokensOverloadMatchesStringOverload() {
        let inputs = [
            "sudo -E \"git\" reset --'hard'",
            "git commit -m \"git reset --hard\"",
            "echo \"git reset --hard\" && \"git\" reset --'hard'",
            "rm $'-rf' /",
            "echo a\ngit status",
            "cat > /tmp/note.md << 'EOF'\nSee git reset --hard\nEOF",
            "cat <<'EOF' | bash\ngit reset --hard\nEOF",
            "\n",
        ]
        for input in inputs {
            #expect(
                applyRoleAwareQuotes(tokens: ShellPipeline.tokenize(input))
                    == applyRoleAwareQuotes(input)
            )
        }
    }
}
