import Testing
import RVDomain
@testable import RVEngine

// The dispatcher is the single seam for shell redirects: stripping before
// the verb scan and the redirect union after it (success, help, failure)
// happen exactly once in `parseFilesystemCommand` (module:
// `WriterRedirectFold`). This matrix pins that interface per verb; the
// per-verb suites pin destination grammar on redirect-stripped argv.
@Suite("Dispatcher redirect fold (T2)")
struct ParseFilesystemRedirectFoldTests {
    struct FoldCase: Sendable {
        var tokens: [String]
        var operation: String
        var paths: [String]
        var recursive: Bool = false
        var force: Bool = false
        var mode: String? = nil
    }

    // Success: verb destinations first, redirect destinations unioned
    // after, operation stays the verb's (REQ-T2: `rm` stays delete).
    @Test(arguments: [
        FoldCase(tokens: ["rm", "-rf", "a", ">", "/out"], operation: "delete", paths: ["a", "/out"], recursive: true, force: true),
        FoldCase(tokens: ["unlink", "a", ">", "/out"], operation: "delete", paths: ["a", "/out"]),
        FoldCase(tokens: ["rmdir", "a", ">", "/out"], operation: "delete", paths: ["a", "/out"]),
        FoldCase(tokens: ["mv", "a", "b", ">", "/out"], operation: "move", paths: ["a", "b", "/out"]),
        FoldCase(tokens: ["mv", "-t", "/dir", "a", ">", "/out"], operation: "move", paths: ["a", "/dir", "/out"]),
        FoldCase(tokens: ["cp", "a", "b", ">", "/out"], operation: "overwrite", paths: ["b", "/out"]),
        FoldCase(tokens: ["tee", "/a", ">", "/out"], operation: "overwrite", paths: ["/a", "/out"]),
        FoldCase(tokens: ["install", "a", "b", ">", "/out"], operation: "overwrite", paths: ["b", "/out"]),
        FoldCase(tokens: ["install", "-d", "sub", ">", "/out"], operation: "create", paths: ["sub", "/out"]),
        FoldCase(tokens: ["ln", "-s", "a", "b", ">", "/out"], operation: "create", paths: ["b", "/out"]),
        FoldCase(tokens: ["rsync", "a", "b", ">", "/out"], operation: "overwrite", paths: ["b", "/out"]),
        FoldCase(tokens: ["tar", "-cf", "/tmp/x.tar", "a", ">", "/out"], operation: "overwrite", paths: ["/tmp/x.tar", "/out"]),
        FoldCase(tokens: ["tar", "-x", "-f", "a.tar", "-C", "/tmp/x", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["curl", "-o", "/tmp/x", "http://h", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["dd", "if=a", "of=/tmp/x", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["wget", "-O", "/tmp/x", "http://h", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["iconv", "-o", "/tmp/x", "f", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["unzip", "a.zip", "-d", "/tmp/x", ">", "/out"], operation: "overwrite", paths: ["/tmp/x", "/out"]),
        FoldCase(tokens: ["split", "big", "/tmp/p", ">", "/out"], operation: "overwrite", paths: ["/tmp/p", "/out"]),
        FoldCase(tokens: ["sed", "-i", "s/a/b/", "f", ">", "/out"], operation: "overwrite", paths: ["f", "/out"]),
        FoldCase(tokens: ["sqlite3", "db", ">", "/out"], operation: "overwrite", paths: ["db", "/out"]),
        FoldCase(tokens: ["ditto", "a", "b", ">", "/out"], operation: "overwrite", paths: ["b", "/out"]),
        FoldCase(tokens: ["gzip", "f", ">", "/out"], operation: "overwrite", paths: ["f", "/out"]),
        FoldCase(tokens: ["zip", "/tmp/a.zip", "f", ">", "/out"], operation: "overwrite", paths: ["/tmp/a.zip", "/out"]),
        FoldCase(tokens: ["chmod", "644", "f", ">", "/out"], operation: "chmod", paths: ["f", "/out"], mode: "644"),
        FoldCase(tokens: ["truncate", "f", ">", "/out"], operation: "overwrite", paths: ["f", "/out"]),
        FoldCase(tokens: ["shred", "f", ">", "/out"], operation: "delete", paths: ["f", "/out"]),
        FoldCase(tokens: ["touch", "f", ">", "/out"], operation: "create", paths: ["f", "/out"]),
        FoldCase(tokens: ["mkdir", "d", ">", "/out"], operation: "create", paths: ["d", "/out"]),
        // cat folds into the same rule: a redirected read claims the
        // redirect target as an overwrite, never the read sources.
        FoldCase(tokens: ["cat", "src", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["echo", "hi", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        // Attached and fd spellings union the same way.
        FoldCase(tokens: ["cp", "a", "b", "2>/out"], operation: "overwrite", paths: ["b", "/out"]),
        FoldCase(tokens: ["cp", "a", "b", ">>", "/out"], operation: "overwrite", paths: ["b", "/out"]),
        // A read-only verb outcome still unions: list modes write nothing
        // themselves, but the shell truncated the redirect target.
        FoldCase(tokens: ["tar", "-tzf", "a.tar", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["unzip", "-l", "a.zip", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["gzip", "-c", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["sed", "s/a/b/", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["sqlite3", "-readonly", "db", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["rsync", "-n", "a", "b", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["rsync", "-n", "--log-file=/tmp/l", "a", "b", ">", "/out"], operation: "overwrite", paths: ["/tmp/l", "/out"]),
        FoldCase(tokens: ["dd", "if=a", "of=/dev/stdout", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        // tar recursive-unlink keeps its delete claim over the union.
        FoldCase(tokens: ["tar", "-x", "-f", "a.tar", "--recursive-unlink", ">", "/out"], operation: "delete", paths: [".", "/out"], recursive: true, force: true),
        // Input redirects never union; the target stays an operand
        // (fail-closed over-approximation, one rule for every verb).
        FoldCase(tokens: ["cp", "a", "b", "<", "/in"], operation: "overwrite", paths: ["/in"]),
        FoldCase(tokens: ["cat", "src", "<", "/in"], operation: "read", paths: ["src", "/in"]),
    ])
    func successUnion(_ foldCase: FoldCase) {
        expectFoldParsed(foldCase)
    }

    // Help: the tool printed and wrote nothing, but the shell still
    // truncated the redirect target (spec §9: `cp --help > /outside`).
    // Verbs whose dest scan is help-blind by design keep their verb
    // destinations (wget below in the REQ pins).
    @Test(arguments: [
        FoldCase(tokens: ["rm", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["cp", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["tee", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["ln", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["rsync", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["tar", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["curl", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["dd", "--help", "of=/tmp/x", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["split", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["sed", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["ditto", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["gzip", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["zip", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["chmod", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["touch", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["cat", "--help", ">", "/out"], operation: "overwrite", paths: ["/out"]),
    ])
    func helpUnion(_ foldCase: FoldCase) {
        expectFoldParsed(foldCase)
    }

    // Failure: an unknown flag fails the verb parse, so only the
    // redirect claim remains — as an overwrite (REQ-T2 redirect-only).
    @Test(arguments: [
        FoldCase(tokens: ["rm", "-z", "a", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["mv", "-z", "a", "b", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["cp", "-z", "a", "b", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["tee", "-z", "/a", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["chmod", "-z", "644", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["truncate", "-z", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["shred", "--bogus", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["touch", "-z", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["mkdir", "-z", "d", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["ln", "-z", "a", "b", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["gzip", "-z", "f", ">", "/out"], operation: "overwrite", paths: ["/out"]),
        FoldCase(tokens: ["cat", "-q", "src", ">", "/out"], operation: "overwrite", paths: ["/out"]),
    ])
    func failureUnion(_ foldCase: FoldCase) {
        expectFoldParsed(foldCase)
    }

    @Test func reqT2FailureSemantics() {
        // Redirect-only is overwrite; `rm` success stays delete even
        // with the union appended.
        expectFoldParsed(FoldCase(tokens: ["echo", "hi", ">", "/out"], operation: "overwrite", paths: ["/out"]))
        expectFoldParsed(FoldCase(tokens: ["rm", "a", ">", "/out"], operation: "delete", paths: ["a", "/out"]))
        // install BSD `-D` destdir survives main-scan failure...
        expectFoldParsed(FoldCase(
            tokens: ["install", "-D/tmp/d", "a", "b", ">", "/out"],
            operation: "overwrite",
            paths: ["/tmp/d", "/out"]
        ))
        expectFoldParsed(FoldCase(
            tokens: ["install", "-D", "/tmp/d", "a", "b", ">", "/out"],
            operation: "overwrite",
            paths: ["b", "/tmp/d", "/out"]
        ))
        expectFoldParsed(FoldCase(
            tokens: ["install", "-z", "-D", "/tmp/d", "a", "b", ">", "/out"],
            operation: "overwrite",
            paths: ["/tmp/d", "/out"]
        ))
        // ...but `--help` drops it (help exits before any install).
        expectFoldParsed(FoldCase(
            tokens: ["install", "--help", "-D", "/tmp/d", ">", "/out"],
            operation: "overwrite",
            paths: ["/out"]
        ))
        // Named strip-before-scan divergences (PR): one-operand `mv`
        // errors in the shell, so only the redirect claim remains; a
        // stripped operator is never a flag value (`curl -o` takes the
        // next surviving word, as the shell would hand it over).
        expectFoldParsed(FoldCase(
            tokens: ["mv", "a", ">", "/out"],
            operation: "overwrite",
            paths: ["/out"]
        ))
        expectFoldParsed(FoldCase(
            tokens: ["curl", "-o", ">", "/out", "http://h"],
            operation: "overwrite",
            paths: ["http://h", "/out"]
        ))
        // wget's output scan is help-blind by design: `-O` still claims
        // beside `--help` (bespoke grammar, REQ-T2 tar/curl clause kin).
        expectFoldParsed(FoldCase(
            tokens: ["wget", "-O", "/tmp/x", "--help", ">", "/out"],
            operation: "overwrite",
            paths: ["/tmp/x", "/out"]
        ))
    }

    @Test func catReadFold() {
        // Without a redirect, cat stays a plain read of its sources.
        expectFoldParsed(FoldCase(tokens: ["cat", "src"], operation: "read", paths: ["src"]))
        // A bare redirected cat claims only the target.
        expectFoldParsed(FoldCase(tokens: ["cat", ">", "/out"], operation: "overwrite", paths: ["/out"]))
    }

    @Test func noRedirectNoFoldChange() {
        expectFoldParsed(FoldCase(tokens: ["cp", "a", "b"], operation: "overwrite", paths: ["b"]))
        expectFoldParsed(FoldCase(tokens: ["rm", "a"], operation: "delete", paths: ["a"]))
        // Fd dups are stripped before the scan and never union.
        expectFoldParsed(FoldCase(tokens: ["rm", "a", "2>&1"], operation: "delete", paths: ["a"]))
        expectFoldParsed(FoldCase(tokens: ["mv", "a", "b", "2>&1"], operation: "move", paths: ["a", "b"]))
        #expect(parseFilesystemCommand(["cp", "--help"]) == nil)
        #expect(parseFilesystemCommand(["rm", "-z", "a"]) == nil)
        #expect(parseFilesystemCommand(["echo", "hi"]) == nil)
    }

    private func expectFoldParsed(_ foldCase: FoldCase) {
        guard let parsed = parseFilesystemCommand(foldCase.tokens) else {
            Issue.record("expected \(foldCase.operation) parse for \(foldCase.tokens)")
            return
        }
        #expect(foldOperationName(parsed.operation) == foldCase.operation, "for \(foldCase.tokens)")
        #expect(parsed.paths == foldCase.paths, "for \(foldCase.tokens)")
        #expect(parsed.recursive == foldCase.recursive, "for \(foldCase.tokens)")
        #expect(parsed.force == foldCase.force, "for \(foldCase.tokens)")
        #expect(parsed.mode == foldCase.mode, "for \(foldCase.tokens)")
    }
}

private func foldOperationName(_ operation: FilesystemOperation) -> String {
    switch operation {
    case .delete: return "delete"
    case .move: return "move"
    case .overwrite: return "overwrite"
    case .chmod: return "chmod"
    case .create: return "create"
    case .read: return "read"
    }
}
