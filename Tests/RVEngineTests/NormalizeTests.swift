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
    #expect(chained.contains("git reset --hard"))
    let echoed = Normalize.matchingView(of: "echo \"git reset --hard\"")
    #expect(!echoed.contains("reset"))
    let commit = Normalize.matchingView(of: "git commit -m \"git push --force\"")
    #expect(!commit.contains("--force"))
    let attached = Normalize.matchingView(of: "git commit --message=\"git reset --hard\"")
    #expect(!attached.contains("reset"))
    let sudoEcho = Normalize.matchingView(of: "sudo echo \"git reset --hard\"")
    #expect(!sudoEcho.contains("reset"))
    let envEcho = Normalize.matchingView(of: "env echo \"git reset --hard\"")
    #expect(!envEcho.contains("reset"))
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
    #expect(Normalize.matchingView(of: "echo $(git reset --hard)").contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo `git reset --hard`").contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"$(git reset --hard)\"").contains("git reset --hard"))
    #expect(Normalize.matchingView(of: "echo \"`git reset --hard`\"").contains("git reset --hard"))
}

@Test func normalize_doesNotExpandTmpdir() {
    #expect(Normalize.matchingView(of: "rm -rf ${TMPDIR}/build") == "rm -rf ${TMPDIR}/build")
}
