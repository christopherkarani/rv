import Testing
import RVDomain
@testable import RVEngine

/// `ShellComments` strips a comment only where every shell reading agrees
/// it runs nothing: bash/zsh scripts (comment) and an interactive zsh or
/// bash with comments off (`#` is a word). Everything else is unchanged.
struct ShellCommentsTests {
    @Test func stripsCommentsOnInertCommands() {
        let cases: [(String, String)] = [
            ("ls # rm -rf /", "ls "),
            ("true # git reset --hard", "true "),
            ("ls -la\t# TODO: tidy, later", "ls -la\t"),
            ("echo 'a # b' # c", "echo 'a # b' "),
            ("echo \"x;y\" # git push --force", "echo \"x;y\" "),
            ("cd repo && ls # rm -rf /", "cd repo && ls "),
            ("ls # x\nrm -rf /", "ls \nrm -rf /"),
            ("pwd # a#b # c", "pwd "),
            (": # rm -rf x/y", ": "),
            ("echo $# # rm -rf /", "echo $# "),
        ]
        for (input, expected) in cases {
            #expect(ShellComments.strippingInertComments(input) == expected, "\(input)")
        }
    }

    /// No comment start: `#` mid-word, escaped, quoted, or after `$`.
    @Test func midWordQuotedAndEscapedHashAreNotComments() {
        for input in [
            "ls a#b", "echo $#", "echo \\# rm -rf /", "echo '# rm -rf /'", "echo \"# rm\"",
            "echo $'# rm'", "ls x#", "ls ''#x", "ls \\ #x",
        ] {
            #expect(ShellComments.strippingInertComments(input) == nil, "\(input)")
        }
    }

    /// Any comment that is not provably inert leaves the whole text as is.
    @Test func leavesEverythingElseUnchanged() {
        for input in [
            // Comment words a literal `#` would hand to a command that acts on them.
            "rm -rf # /", "find . # -delete", "git push # --force", "sudo ls # x",
            "FOO=1 ls # x", "\\ls # x", "l''s # x", "ls; rm -rf # /",
            // Command-position comments.
            "# rm -rf /", "ls\n# rm -rf /", "ls; # rm -rf /",
            // Comment text with shell syntax a literal `#` would run.
            "ls # ; rm -rf /", "ls # && rm -rf /", "ls # | sh", "ls # > ~/.bashrc",
            "ls # $(rm -rf /)", "ls # `rm`", "ls # don't", "ls # \"x\"", "ls # *",
            "ls # ~", "ls # a=b", "ls # !rm", "ls # {a,b}", "ls # x\\", "ls # caf\u{00E9}",
            "ls # x\r\nrm",
            // Constructs whose quoting the scan does not model.
            "echo $(ls # x\n)", "echo `ls # x`", "echo ${x#y} # z", "echo $[1] # z",
            "(ls # x\n)", "ls *(#q) # x", "[[ -n x ]] # y", "cat <<EOF # x\nrm -rf /\nEOF",
            "cat <<< x # y", "ls >#x", "ls;#x", "ls|#x", "ls \\\n# x", "echo 'open # x",
            "echo \"open # x", "echo \"$(x)\" # y",
        ] {
            #expect(ShellComments.strippingInertComments(input) == nil, "\(input)")
        }
    }

    @Test func stripCountsAsBashDoes() {
        // A comment ends at the newline: the next line still runs.
        #expect(ShellComments.strippingInertComments("ls # a\nls # b") == "ls \nls ")
        #expect(ShellComments.strippingInertComments("ls #") == "ls ")
    }
}
