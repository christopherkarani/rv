import Testing
import RVDomain
@testable import RVEngine

// T3: one matching-derivation pass yields the classified view plus every
// side-channel (masked lexemes, erased prefix, assignment-value budget) in
// a single result. These tests pin the bundle shape and the projection
// entry points that delegate to it.

@Test func deriveMatching_bundlesAllChannels() {
    let derivation = ShellPipeline.deriveMatching("FOO=bar sudo git reset --hard")
    #expect(derivation.view == "git reset --hard")
    #expect(derivation.masked == [])
    #expect(
        derivation.prefix == [
            .assignment(name: "FOO", raw: "FOO=bar"),
            .wrapper(head: "sudo"),
        ]
    )
    #expect(derivation.assignmentValues == [])
}

@Test func deriveMatching_bundlesFullCombination() {
    let derivation = ShellPipeline.deriveMatching("FOO=bar sudo /bin/git reset --hard")
    #expect(derivation.view == "git reset --hard")
    #expect(derivation.prefix.map(\.raw) == ["FOO=bar", "sudo", "/bin/git"])
}

@Test func deriveMatching_recordsWrappersBehindMaskedTails() {
    // Masking pads a trailing masked lexeme with spaces. The legacy
    // recorder split heads on a raw suffix, so it missed the wrapper
    // exactly when the tail was masked — while the view stripped it. The
    // fused loop strips and records atomically, so the prefix always
    // describes the view.
    let sudo = ShellPipeline.deriveMatching(#"sudo echo "secret""#)
    #expect(sudo.view == "echo")
    #expect(sudo.masked == ["secret"])
    #expect(sudo.prefix.map(\.raw) == ["sudo"])

    let env = ShellPipeline.deriveMatching("env FOO=1 echo aaa")
    #expect(env.view == "echo")
    #expect(env.masked == ["aaa"])
    #expect(env.prefix.map(\.raw) == ["env FOO=1"])

    let pathed = ShellPipeline.deriveMatching(#"sudo /bin/echo "secret""#)
    #expect(pathed.view == "echo")
    #expect(pathed.prefix.map(\.raw) == ["sudo", "/bin/echo"])
}

@Test func deriveMatching_bundlesAssignmentBudget() {
    let derivation = ShellPipeline.deriveMatching("A=$(a) B=1 git push")
    #expect(derivation.assignmentValues == ["$(a)"])
    #expect(derivation.prefix.map(\.raw) == ["A=$(a)", "B=1"])

    let perSegment = ShellPipeline.deriveMatching("A=1 git reset --hard; B=$(b) git status")
    #expect(perSegment.assignmentValues == ["$(b)"])
    #expect(perSegment.prefix.map(\.raw) == ["A=1", "B=$(b)"])
}

@Test func deriveMatching_heredocBodyLeadsMasked() {
    let derivation = ShellPipeline.deriveMatching("cat <<EOF\nhello\nEOF")
    #expect(derivation.masked == ["hello"])
    #expect(derivation.prefix == [])
    #expect(derivation.assignmentValues == [])
}

@Test func deriveMatching_emptyInputIsEmptyBundle() {
    for input in ["", "   "] {
        let derivation = ShellPipeline.deriveMatching(input)
        #expect(derivation.view == MatchingView(""))
        #expect(derivation.masked == [])
        #expect(derivation.prefix == [])
        #expect(derivation.assignmentValues == [])
    }
}

@Test func deriveMatching_projectionsMatchEntryPoints() {
    // Every public/internal entry point projects its field from the same
    // bundle the derivation returns.
    let corpus = [
        "git reset --hard",
        "sudo git reset --hard",
        "sudo -u root git reset --hard",
        "env GIT_DIR=.git git reset --hard",
        "command git reset --hard",
        "command -v git",
        "\\git reset --hard",
        "/usr/bin/git reset --hard",
        "FOO=bar BAZ=qux git reset --hard",
        "X=$(echo hi) git reset --hard",
        "A=(1 2) git push",
        "sudo env FOO=bar git reset --hard",
        "$'sudo' git reset --hard",
        #"git commit -m "ship it""#,
        #"sudo echo "secret""#,
        "echo aaa",
        "cat <<EOF\nhello\nEOF",
        "A=1 git reset --hard; B=2 git status",
        "",
        "   ",
    ]
    for input in corpus {
        let derivation = ShellPipeline.deriveMatching(input)
        #expect(
            Normalize.matchingView(of: input) == derivation.view,
            "view drift for: \(input)"
        )
        #expect(
            Normalize.maskedSegments(of: input) == derivation.masked,
            "masked drift for: \(input)"
        )
        #expect(
            Normalize.invocationPrefix(of: input) == derivation.prefix.map(\.raw),
            "prefix drift for: \(input)"
        )
        #expect(
            ShellPipeline.classifyStage(ShellPipeline.peelStage(input)) == derivation.view,
            "classify drift for: \(input)"
        )
        #expect(
            ShellPipeline.collectTopLevelAssignmentValues(ShellPipeline.peelStage(input))
                == derivation.assignmentValues,
            "budget drift for: \(input)"
        )
    }
}
