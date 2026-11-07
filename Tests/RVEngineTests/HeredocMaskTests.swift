import Testing
@testable import RVEngine

/// Heredoc masking blanks the body where the parser found it. It must
/// never blank an earlier copy of the body text, and a body it cannot
/// place unambiguously stays visible (over-deny, never under-deny).
@Suite("Heredoc body masking")
struct HeredocMaskTests {
    @Test(arguments: [
        ("git reset --hard\ncat <<EOF\ngit\nEOF", "git reset --hard\ncat <<EOF\n   \nEOF"),
        (
            "git reset --hard && cat <<EOF > notes.txt\ngit\nEOF",
            "git reset --hard && cat <<EOF > notes.txt\n   \nEOF"
        ),
        ("rm -rf ~\ncat <<EOF\nrm\nEOF", "rm -rf ~\ncat <<EOF\n  \nEOF"),
        ("git clean -fdx\ncat <<EOF\nclean\nEOF", "git clean -fdx\ncat <<EOF\n     \nEOF"),
        ("rm -rf ~ && cat <<-EOF\n\trm\n\tEOF", "rm -rf ~ && cat <<-EOF\n\t  \n\tEOF"),
        ("rm -rf ~ && cat <<'EOF'\nrm\nEOF", "rm -rf ~ && cat <<'EOF'\n  \nEOF"),
        ("rm -rf ~ && cat <<\"EOF\"\nrm\nEOF", "rm -rf ~ && cat <<\"EOF\"\n  \nEOF"),
    ])
    func blanksTheBodyNotAnEarlierCopy(command: String, view: String) {
        #expect(maskNonExecutingHeredocBodies(command) == view)
    }

    @Test func bodyMatchingALaterSegmentBlanksOnlyTheBody() {
        let command = "cat <<EOF > f\ngit reset --hard\nEOF\ngit reset --hard"
        #expect(maskNonExecutingHeredocBodies(command) == "cat <<EOF > f\n                \nEOF\ngit reset --hard")
    }

    @Test func firstOfSeveralHeredocsIsTheOnlyOneMasked() {
        let command = "cat <<A > a\nx\nA\ngit reset --hard\ncat <<B > b\nreset\nB"
        #expect(maskNonExecutingHeredocBodies(command) == "cat <<A > a\n \nA\ngit reset --hard\ncat <<B > b\nreset\nB")
    }

    @Test func multiLineBodyIsBlankedAsBefore() {
        let command = "cat > /tmp/n.md <<'EOF'\n  # Notes\n\ngit status\n  \nEOF\necho ok"
        let (view, masked) = maskNonExecutingHeredocBodiesDetailed(command)
        #expect(masked == ["# Notes\n\ngit status"])
        #expect(view == "cat > /tmp/n.md <<'EOF'\n  " + String(repeating: " ", count: 19) + "\n  \nEOF\necho ok")
    }

    /// Positions the parser cannot pin down: each leaves the text as is.
    @Test(arguments: [
        // No terminator line.
        "cat <<EOF > f\nx\nrm -rf ~",
        // A carriage return on the header line.
        "cat <<EOF > f\r\nx\nEOF\nrm -rf ~",
        // Delimiter words bash unquotes differently.
        "cat <<E\"OF\" > f\nx\nEOF\nrm -rf ~\nE\"OF\"",
        "cat <<\\EOF > f\nx\nEOF\nrm -rf ~\n\\EOF",
        "cat <<'EO'F > f\nx\nEOF\nrm -rf ~\nEO",
        // A backslash or comment before the operator.
        "echo \\<<EOF\nrm -rf ~\nEOF",
        "echo hi # <<EOF\nrm -rf ~\nEOF",
        "# <<EOF\nrm -rf ~\nEOF",
        "echo \"\\\" <<EOF\n\" ; rm -rf ~\nEOF",
        "echo \"a\\\\\\\" <<EOF\n\" ; rm -rf ~\nEOF",
        // A header line that runs past its newline.
        "cat <<EOF > f \"\n\"; rm -rf ~\nx\nEOF",
        "cat <<EOF > f \\\nrm -rf ~\nEOF",
        "cat <<EOF > f \"\\\"\" \"\n\"; rm -rf ~\nx\nEOF",
        // Two heredocs on one header line.
        "cat <<A <<B > f\nx\nA\ny\nB",
        // An operator inside an expansion this scan does not close.
        "echo ${x:-<<x}\nrm -rf ~\nx}",
        "echo $[1<<2]\nrm -rf ~\n2]",
        // An earlier nested heredoc whose body holds a closing paren or quote.
        "( cat <<'A'\n)\ncat <<B\nA\n)\nrm -rf ~\nB",
        "x=$(cat <<'A'\n)\ncat <<B\nA\n)\nrm -rf ~\nB",
        "x=\"$(cat <<'A'\n\" ; cat <<B >f\nA\n)\"\nrm -rf ~\nB",
        // An ANSI-C quote, where `\'` does not close.
        "echo $'\\' <<EOF ''\nrm -rf ~\nEOF",
    ])
    func unplaceableBodyStaysVisible(command: String) {
        #expect(maskNonExecutingHeredocBodies(command) == command)
        #expect(locateHeredoc(command)?.bodyRange == nil)
    }

    /// Backslashes that cannot hide a quote or the operator: single-quoted,
    /// a plain escape inside double quotes, or a line continuation.
    @Test(arguments: [
        "gh pr create --title \"fix: x\" \\\n  --body-file - <<'EOF'\nStop rm -rf in setup\nEOF",
        "git commit \\\n  -F - <<'EOF'\nfix: stop git reset --hard in setup\nEOF",
        "printf '%s\\n' done && cat > notes.md <<'EOF'\ngit reset --hard\nEOF",
        "echo \"a\\tb\" && cat > f <<'EOF'\ngit reset --hard\nEOF",
        "sed -i '' 's/a\\.b/c/' x && cat <<'EOF' > f\ngit reset --hard\nEOF",
        "echo \"path: C:\\\\tmp\" && cat <<'EOF' > f\ngit reset --hard\nEOF",
    ])
    func harmlessBackslashStillMasks(command: String) throws {
        // Each command's body is its second-to-last line.
        var lines = command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines[lines.count - 2]
        lines[lines.count - 2] = String(repeating: " ", count: body.count)
        #expect(maskNonExecutingHeredocBodies(command) == lines.joined(separator: "\n"))
    }

    /// Bash splits heredoc lines on LF alone; CR stays part of a line.
    @Test func crlfBodyUnderAnLFHeaderMasks() {
        let command = "cat <<'EOF' > f\nline one\r\ngit reset --hard\r\nEOF\n"
        let (view, masked) = maskNonExecutingHeredocBodiesDetailed(command)
        #expect(view == "cat <<'EOF' > f\n" + String(repeating: " ", count: 25) + "\r\nEOF\n")
        #expect(masked == ["line one\r\ngit reset --hard"])
    }

    /// `x\r` is a body line and `EOF` ends the body, so `rm -rf ~` runs.
    @Test func crlfCannotHideTheTerminator() {
        let command = "cat <<EOF > f\nx\r\nEOF\nrm -rf ~\nEOF"
        #expect(maskNonExecutingHeredocBodies(command) == "cat <<EOF > f\n \r\nEOF\nrm -rf ~\nEOF")
    }

    @Test func extractHeredocKeepsItsHeaderAndBody() throws {
        let parsed = try #require(extractHeredoc("cat <<-'EOF' > f\n\tline\n\tEOF\nnext"))
        #expect(parsed.header == "cat <<-'EOF' > f")
        #expect(parsed.body == "line")
        let unterminated = try #require(extractHeredoc("cat <<EOF\nx\ny"))
        #expect(unterminated.body == "x\ny")
    }

    @Test(arguments: [
        "grep foo <<< 'git reset --hard'",
        "git reset --hard\ncat <<< git",
        "cat <<< x\nrm -rf ~",
    ])
    func hereStringsAreNotHeredocs(command: String) {
        #expect(locateHeredoc(command) == nil)
        #expect(maskNonExecutingHeredocBodies(command) == command)
    }
}
