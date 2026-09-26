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
        let commit = ShellPipeline.parse("git commit -m \"git reset --hard\"").matching
        #expect(commit.rawValue.contains("--force") == false)
        let attached = ShellPipeline.parse("git commit --message=\"git reset --hard\"").matching
        #expect(attached.rawValue.contains("reset") == false)
        let search = ShellPipeline.parse("git grep -n \"rm -rf\"").matching
        #expect(search.rawValue.contains("rm") == false)
        #expect(search.rawValue.contains(".env") == false)
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
                .contains("--force") == false
        )
    }

    @Test func roleAwareQuotes_tokensOverloadMatchesStringOverload() {
        let inputs = [
            "sudo -E \"git\" reset --'hard'",
            "git commit -m \"git reset --hard\"",
            "echo \"git reset --hard\" && \"git\" reset --'hard'",
            "rm $'-rf' /",
        ]
        for input in inputs {
            #expect(
                applyRoleAwareQuotes(tokens: ShellPipeline.tokenize(input))
                    == applyRoleAwareQuotes(input)
            )
        }
    }
}
