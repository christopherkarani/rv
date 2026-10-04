import Testing
import RVDomain
@testable import RVEngine

@Suite("Mid-word redirect split (Step 8B P10c)")
struct MidWordRedirectSplitTests {
    @Test func split_wordOpTargetPieces() {
        #expect(words("b>/tmp/x") == ["b", ">", "/tmp/x"])
        #expect(words("a2>>b") == ["a", "2>>", "b"])
        #expect(words("a>/tmp/x>/tmp/y") == ["a", ">", "/tmp/x", ">", "/tmp/y"])
        #expect(words("a>&/tmp/f") == ["a", ">&", "/tmp/f"])
        #expect(words("a<>b") == ["a", "<>", "b"])
        #expect(words("a<<<b") == ["a", "<<<", "b"])
        #expect(words("a<<-EOF") == ["a", "<<-", "EOF"])
        #expect(words("a10>b") == ["a", "10>", "b"])
    }

    @Test func split_dupCloseTargetsStayGlued() {
        #expect(words("2>&1") == ["2>&1"])
        #expect(words("a2>&1") == ["a", "2>&1"])
        #expect(words(">&-") == [">&-"])
        #expect(words("a<&-") == ["a", "<&-"])
        // `>&1b` duplicates to the FILE `1b`, not fd 1.
        #expect(words("a>&1b") == ["a", ">&", "1b"])
    }

    @Test func split_quotedDynamicUntouched() {
        #expect(tokenizeFilesystemWords("\"a>b\"") == ["a>b"])
        #expect(tokenizeFilesystemWords("\"a>/tmp/x\"") == ["a>/tmp/x"])
        #expect(tokenizeFilesystemWords("a$X>b") == ["a$X>b"])
        // Backslash-escaped metachars never split.
        #expect(tokenizeFilesystemWords(#"a\>b"#) == [#"a\>b"#])
    }

    @Test func split_endToEndMidWordRedirect() {
        expectSplitParsed(
            parseFilesystemCommand(tokenizeFilesystemWords("echo hi>/tmp/x")),
            "overwrite",
            paths: ["/tmp/x"]
        )
        expectSplitParsed(
            parseFilesystemCommand(tokenizeFilesystemWords("cp a b>/tmp/log")),
            "overwrite",
            paths: ["b", "/tmp/log"]
        )
        expectSplitParsed(
            parseFilesystemCommand(tokenizeFilesystemWords("mv a b>/tmp/log")),
            "move",
            paths: ["a", "b", ">", "/tmp/log"]
        )
    }
}

private func words(_ text: String) -> [String] {
    tokenizeFilesystemWords(text)
}

private func expectSplitParsed(
    _ parsed: ParsedFilesystemCommand?,
    _ operation: String,
    paths: [String]
) {
    guard let parsed else {
        Issue.record("expected \(operation) parse")
        return
    }
    #expect(splitOperationName(parsed.operation) == operation)
    #expect(parsed.paths == paths)
}

private func splitOperationName(_ operation: FilesystemOperation) -> String {
    switch operation {
    case .delete: return "delete"
    case .move: return "move"
    case .overwrite: return "overwrite"
    case .chmod: return "chmod"
    case .create: return "create"
    case .read: return "read"
    }
}
