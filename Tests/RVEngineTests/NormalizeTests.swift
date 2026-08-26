import Testing
@testable import RVEngine

@Test func normalize_stripsWrappersAndPath() {
    #expect(Normalize.matchingView(of: "  sudo git reset --hard  ") == "git reset --hard")
    #expect(Normalize.matchingView(of: "env GIT_DIR=.git git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "command git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "\\git reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "/usr/bin/git reset --hard") == "git reset --hard")
}

@Test func normalize_keepsCommandQuery() {
    #expect(Normalize.matchingView(of: "command -v git") == "command -v git")
    #expect(Normalize.matchingView(of: "command -V git") == "command -V git")
}

@Test func normalize_roleAwareQuotes() {
    #expect(Normalize.matchingView(of: "\"git\" reset --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git reset '--hard'") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git \"reset\" --hard") == "git reset --hard")
    #expect(Normalize.matchingView(of: "sudo \"git\" reset --hard") == "git reset --hard")
    let chained = Normalize.matchingView(of: "echo hello && \"git\" reset --hard")
    #expect(chained.rawValue.contains("git reset --hard"))
    let echoed = Normalize.matchingView(of: "echo \"git reset --hard\"")
    #expect(!echoed.rawValue.contains("reset"))
    let commit = Normalize.matchingView(of: "git commit -m \"git push --force\"")
    #expect(!commit.rawValue.contains("--force"))
    let attached = Normalize.matchingView(of: "git commit --message=\"git reset --hard\"")
    #expect(!attached.rawValue.contains("reset"))
    let sudoEcho = Normalize.matchingView(of: "sudo echo \"git reset --hard\"")
    #expect(!sudoEcho.rawValue.contains("reset"))
    let envEcho = Normalize.matchingView(of: "env echo \"git reset --hard\"")
    #expect(!envEcho.rawValue.contains("reset"))
}

@Test func normalize_tokenizerPreservesBoundariesAndInlineCode() {
    let tokens = tokenizeCommand(#""git" reset --'hard' "$(git reset --hard)" `git status`"#)

    #expect(tokens.map(\.decoded) == [
        "git",
        "reset",
        "--hard",
        "$(git reset --hard)",
        "`git status`",
    ])
    #expect(tokens.map(\.wasQuoted) == [true, false, true, true, true])
}

@Test func normalize_roleAwareQuotesPreservesWrappersAndSeparators() {
    #expect(applyRoleAwareQuotes("sudo -E \"git\" reset --'hard'") == "sudo -E git reset --hard")
    #expect(applyRoleAwareQuotes("env FOO=bar \"git\" reset --\"hard\"") == "env FOO=bar git reset --hard")
    #expect(
        applyRoleAwareQuotes("echo \"git reset --hard\" && \"git\" reset --'hard'")
            == "echo " + String(repeating: " ", count: 16) + " && git reset --hard"
    )
    #expect(applyRoleAwareQuotes("echo \"$(git reset --hard)\" | printf `git status`")
        == "echo $(git reset --hard) | printf `git status`")
}

@Test func normalize_roleAwareQuotesMasksOnlyDataRoles() {
    let commit = String(repeating: " ", count: 16)
    #expect(applyRoleAwareQuotes("git commit -m \"git reset --hard\"") == "git commit -m " + commit)
    #expect(applyRoleAwareQuotes("git commit --message=\"git reset --hard\"") == "git commit --message=" + commit)
    #expect(applyRoleAwareQuotes("rg -e \"git reset --hard\"") == "rg -e " + commit)
    #expect(applyRoleAwareQuotes("git reset \"--hard\"") == "git reset --hard")
}

@Test func normalize_concatenatesAdjacentQuotes() {
    #expect(Normalize.matchingView(of: "git reset --'hard'") == "git reset --hard")
    #expect(Normalize.matchingView(of: "git reset --\"hard\"") == "git reset --hard")
}

@Test func normalize_doesNotStripRedirectAsArgv0() {
    #expect(Normalize.matchingView(of: ">/etc/passwd") == ">/etc/passwd")
    #expect(Normalize.matchingView(of: "1>/etc/passwd") == "1>/etc/passwd")
    #expect(Normalize.matchingView(of: "&>/etc/passwd") == "&>/etc/passwd")
}

@Test func normalize_doesNotMaskSubstitutions() {
    #expect(Normalize.matchingView(of: "echo $(git reset --hard)").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo `git reset --hard`").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"$(git reset --hard)\"").rawValue.contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"`git reset --hard`\"").rawValue.contains("git reset --hard"))
}

@Test func normalize_doesNotExpandTmpdir() {
    #expect(Normalize.matchingView(of: "rm -rf ${TMPDIR}/build") == "rm -rf ${TMPDIR}/build")
}
