import Testing
import RVDomain
@testable import RVEngine

// M-07: authority grants must bind the exact payload masking replaced, not
// just the masked view. These tests pin the masked-segment extraction that
// mint and spend both digest.

@Test func maskedSegments_pythonC_sameViewDifferentPayload() {
    let a = #"python -c "import os""#
    let b = #"python -c "import sys""#
    #expect(Normalize.matchingView(of: a) == Normalize.matchingView(of: b))
    let segA = Normalize.maskedSegments(of: a)
    let segB = Normalize.maskedSegments(of: b)
    #expect(segA.isEmpty == false)
    #expect(segA != segB)
}

@Test func maskedSegments_echoSameLengthCollision() {
    #expect(Normalize.matchingView(of: "echo aaa") == Normalize.matchingView(of: "echo bbb"))
    #expect(Normalize.maskedSegments(of: "echo aaa") == ["aaa"])
    #expect(Normalize.maskedSegments(of: "echo bbb") == ["bbb"])
}

@Test func maskedSegments_identicalCommandIsStable() {
    let command = #"git commit -m "ship it""#
    #expect(Normalize.maskedSegments(of: command) == Normalize.maskedSegments(of: command))
    #expect(Normalize.maskedSegments(of: command) == ["ship it"])
}

@Test func maskedSegments_quotingVariantsDecodeEqual() {
    let doubleQuoted = #"python -c "ab""#
    let singleQuoted = "python -c 'ab'"
    #expect(Normalize.maskedSegments(of: doubleQuoted) == ["ab"])
    #expect(Normalize.maskedSegments(of: singleQuoted) == ["ab"])
}

@Test func maskedSegments_unmaskedCommandIsEmpty() {
    #expect(Normalize.maskedSegments(of: "git reset --hard").isEmpty)
    #expect(Normalize.maskedSegments(of: "ls -la /tmp").isEmpty)
    #expect(Normalize.maskedSegments(of: "").isEmpty)
}

@Test func maskedSegments_sedScriptAndAttachedForms() {
    #expect(Normalize.maskedSegments(of: #"sed -i "s/a/b/" /tmp/x"#) == ["s/a/b/"])
    #expect(Normalize.maskedSegments(of: "gh pr create --body=topsecret") == ["--body=topsecret"])
    #expect(Normalize.maskedSegments(of: #"git commit --message="hello""#) == ["--message=hello"])
}

@Test func maskedSegments_heredocBodyOnlyWhenMasked() {
    let data = "cat <<EOF\nhello\nEOF"
    #expect(Normalize.maskedSegments(of: data) == ["hello"])
    let executing = "cat <<EOF | bash\necho hi\nEOF"
    #expect(Normalize.maskedSegments(of: executing).isEmpty)
}

@Test func maskedSegments_shellCommandOverloadParity() {
    let raw = #"rg -e "secret-pattern""#
    #expect(Normalize.maskedSegments(of: ShellCommand(rawValue: raw)) == Normalize.maskedSegments(of: raw))
    #expect(Normalize.maskedSegments(of: ShellCommand(rawValue: raw)) == ["secret-pattern"])
}
