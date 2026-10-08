import Testing
import RVDomain
@testable import RVEngine

// B1: the invocation recorder must capture exactly what the matching view
// erases — wrappers, assignments, and the argv0 path — so grants bind the
// executed spelling, not just the normalized view.

// MARK: - Extraction

@Test func invocationPrefix_bareCommandIsEmpty() {
    #expect(Normalize.invocationPrefix(of: "git reset --hard") == [])
    #expect(Normalize.invocationPrefix(of: "") == [])
    #expect(Normalize.invocationPrefix(of: "   ") == [])
}

@Test func invocationPrefix_recordsSudoWithFlags() {
    #expect(Normalize.invocationPrefix(of: "sudo git reset --hard") == ["sudo"])
    // Flag-skipping stops at the first non-flag (`root` stays in the
    // view); the recorded head is exactly the erased span.
    #expect(Normalize.invocationPrefix(of: "sudo -u root git reset --hard") == ["sudo -u"])
    #expect(Normalize.invocationPrefix(of: "sudo -- git reset --hard") == ["sudo --"])
    // Long flags are not stripped from the view, so nothing is erased.
    #expect(Normalize.invocationPrefix(of: "sudo --user=root git reset --hard") == [])
}

@Test func invocationPrefix_recordsEnvAndCommand() {
    #expect(
        Normalize.invocationPrefix(of: "env GIT_DIR=.git git reset --hard")
            == ["env GIT_DIR=.git"]
    )
    #expect(Normalize.invocationPrefix(of: "env -i git reset --hard") == ["env -i"])
    #expect(Normalize.invocationPrefix(of: "command git reset --hard") == ["command"])
    #expect(Normalize.invocationPrefix(of: "\\git reset --hard") == ["\\"])
}

@Test func invocationPrefix_recordsWrapperChainsInOrder() {
    #expect(
        Normalize.invocationPrefix(of: "sudo env FOO=bar git reset --hard")
            == ["sudo", "env FOO=bar"]
    )
    #expect(
        Normalize.invocationPrefix(of: "env A=1 sudo git reset --hard")
            == ["env A=1", "sudo"]
    )
}

@Test func invocationPrefix_recordsAssignments() {
    #expect(Normalize.invocationPrefix(of: "FOO=bar git reset --hard") == ["FOO=bar"])
    #expect(
        Normalize.invocationPrefix(of: "FOO=bar BAZ=qux git reset --hard")
            == ["FOO=bar", "BAZ=qux"]
    )
    // Boundary blanks do not leak into the binding: spacing variants
    // of one assignment share the grant.
    #expect(Normalize.invocationPrefix(of: "FOO=bar  git reset --hard") == ["FOO=bar"])
    // Substitution carriers bind the raw span even though the value is
    // rewritten into the view.
    #expect(Normalize.invocationPrefix(of: "X=$(echo hi) git reset --hard") == ["X=$(echo hi)"])
}

@Test func invocationPrefix_recordsAbsoluteArgv0() {
    #expect(
        Normalize.invocationPrefix(of: "/usr/bin/git reset --hard") == ["/usr/bin/git"]
    )
    // Relative argv0 paths are stripped from the view too, so they bind.
    #expect(Normalize.invocationPrefix(of: "./git reset --hard") == ["./git"])
    #expect(Normalize.invocationPrefix(of: "../bin/git reset --hard") == ["../bin/git"])
    #expect(Normalize.invocationPrefix(of: "git reset --hard") == [])
}

@Test func invocationPrefix_recordsAnsiCWrapperAfterMasking() {
    // `$'sudo'` only surfaces as a wrapper after masking; the recorder
    // runs on the same masked text as the view pipeline.
    let view = Normalize.matchingView(of: "$'sudo' git reset --hard")
    #expect(view == "git reset --hard")
    #expect(Normalize.invocationPrefix(of: "$'sudo' git reset --hard") == ["sudo"])
}

@Test func invocationPrefix_recordsPerSegment() {
    #expect(
        Normalize.invocationPrefix(of: "A=1 git reset --hard; B=2 git status")
            == ["A=1", "B=2"]
    )
    #expect(
        Normalize.invocationPrefix(of: "sudo git reset --hard && git status")
            == ["sudo"]
    )
}

@Test func invocationPrefix_fullCombination() {
    #expect(
        Normalize.invocationPrefix(of: "FOO=bar sudo /bin/git reset --hard")
            == ["FOO=bar", "sudo", "/bin/git"]
    )
}

// MARK: - Display

@Test func invocationDisplay_bareCommandIsNil() {
    #expect(Normalize.invocationDisplay(of: "git reset --hard") == nil)
    #expect(Normalize.invocationDisplay(of: "") == nil)
}

@Test func invocationDisplay_namesWrappersWithoutFlags() {
    #expect(Normalize.invocationDisplay(of: "sudo git reset --hard") == "sudo")
    #expect(Normalize.invocationDisplay(of: "sudo -u root git reset --hard") == "sudo")
    #expect(Normalize.invocationDisplay(of: "sudo env FOO=bar git reset --hard") == "sudo env")
}

@Test func invocationDisplay_namesAssignmentsWithoutValues() {
    #expect(Normalize.invocationDisplay(of: "FOO=bar git reset --hard") == "FOO=…")
    #expect(
        Normalize.invocationDisplay(of: "TOKEN=s3cr3t git reset --hard") == "TOKEN=…"
    )
    #expect(
        Normalize.invocationDisplay(of: "FOO=bar sudo git reset --hard") == "FOO=… sudo"
    )
}

@Test func invocationDisplay_showsPathedArgv0() {
    #expect(
        Normalize.invocationDisplay(of: "/usr/bin/git reset --hard") == "/usr/bin/git"
    )
}
