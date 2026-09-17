import Testing
import RVDomain
@testable import RVEngine

@Suite("Parse filesystem mutations")
struct ParseFilesystemMutationsTests {
    @Test func rm_modeledFlagsForceRecursiveAndDashDash() {
        expectParsed(
            parseRm(["--recursive", "--force", "--verbose", "file"]),
            "delete",
            paths: ["file"],
            recursive: true,
            force: true
        )
        expectParsed(
            parseRm(["--dir", "--interactive", "dir"]),
            "delete",
            paths: ["dir"],
            recursive: true
        )
        expectParsed(
            parseRm(["--directory", "--one-file-system", "--preserve-root", "--no-preserve-root", "x"]),
            "delete",
            paths: ["x"],
            recursive: true
        )
        expectParsed(
            parseRm(["-rRdfviI", "tree"]),
            "delete",
            paths: ["tree"],
            recursive: true,
            force: true
        )
        expectParsed(
            parseRm(["--", "-rf", "file"]),
            "delete",
            paths: ["-rf", "file"]
        )
        expectParsed(
            parseFilesystemCommand(["/bin/rm", "-rf", ".build"]),
            "delete",
            paths: [".build"],
            recursive: true,
            force: true
        )
    }

    @Test func rm_rejectsUnknownAndEmpty() {
        #expect(parseRm(["-z", "file"]) == nil)
        #expect(parseRm(["--weird", "file"]) == nil)
        #expect(parseRm([]) == nil)
    }

    @Test func unlink_singlePathOnly() {
        expectParsed(parseUnlink(["file"]), "delete", paths: ["file"])
        expectParsed(parseUnlink(["--", "file"]), "delete", paths: ["file"])
        #expect(parseUnlink(["--help"]) == nil)
        #expect(parseUnlink(["--version"]) == nil)
        #expect(parseUnlink(["-f", "file"]) == nil)
        #expect(parseUnlink(["a", "b"]) == nil)
        #expect(parseUnlink([]) == nil)
        expectParsed(
            parseFilesystemCommand(["unlink", "only"]),
            "delete",
            paths: ["only"]
        )
    }

    @Test func rmdir_modeledFlagsAndDashDash() {
        expectParsed(
            parseRmdir(["--parents", "--verbose", "--ignore-fail-on-non-empty", "dir"]),
            "delete",
            paths: ["dir"]
        )
        expectParsed(
            parseRmdir(["-pv", "nested"]),
            "delete",
            paths: ["nested"]
        )
        expectParsed(
            parseRmdir(["--", "-p"]),
            "delete",
            paths: ["-p"]
        )
        expectParsed(
            parseFilesystemCommand(["rmdir", "empty"]),
            "delete",
            paths: ["empty"]
        )
        #expect(parseRmdir(["-z", "dir"]) == nil)
        #expect(parseRmdir(["--weird", "dir"]) == nil)
        #expect(parseRmdir([]) == nil)
    }

    @Test func mv_requiresTwoPaths() {
        expectParsed(
            parseMv(["--force", "--interactive", "--no-clobber", "--verbose", "--update", "src", "dst"]),
            "move",
            paths: ["src", "dst"]
        )
        expectParsed(
            parseMv(["-finvu", "a", "b", "c"]),
            "move",
            paths: ["a", "b", "c"]
        )
        expectParsed(
            parseMv(["--", "-f", "dst"]),
            "move",
            paths: ["-f", "dst"]
        )
        expectParsed(
            parseFilesystemCommand(["mv", "Sources/Foo.swift", "/tmp/out"]),
            "move",
            paths: ["Sources/Foo.swift", "/tmp/out"]
        )
        #expect(parseMv(["-z", "a", "b"]) == nil)
        #expect(parseMv(["--weird", "a", "b"]) == nil)
        #expect(parseMv(["only"]) == nil)
        #expect(parseMv([]) == nil)
    }

    @Test func truncate_sizeFlagsAndSkip() {
        expectParsed(
            parseTruncate(["-s", "0", "--no-create", "file"]),
            "overwrite",
            paths: ["file"]
        )
        expectParsed(
            parseTruncate(["--size", "1K", "--io-blocks", "--verbose", "a"]),
            "overwrite",
            paths: ["a"]
        )
        expectParsed(
            parseTruncate(["--size=0", "-cor", "x"]),
            "overwrite",
            paths: ["x"]
        )
        #expect(parseTruncate(["-s0", "y"]) == nil)
        expectParsed(
            parseTruncate(["--", "-s"]),
            "overwrite",
            paths: ["-s"]
        )
        expectParsed(
            parseFilesystemCommand(["truncate", "out"]),
            "overwrite",
            paths: ["out"]
        )
        #expect(parseTruncate(["-s"]) == nil)
        #expect(parseTruncate(["-z", "file"]) == nil)
        #expect(parseTruncate(["--weird", "file"]) == nil)
        #expect(parseTruncate([]) == nil)
    }

    @Test func shred_iterationsSizeAndSkip() {
        expectParsed(
            parseShred(["--iterations", "3", "--size", "1K", "--force", "file"]),
            "delete",
            paths: ["file"]
        )
        expectParsed(
            parseShred(["--remove=unlink", "--iterations=2", "--size=4", "--zero", "--verbose", "--exact", "x"]),
            "delete",
            paths: ["x"]
        )
        expectParsed(
            parseShred(["-fuzvx", "-n", "2", "-s", "4", "y"]),
            "delete",
            paths: ["y"]
        )
        #expect(parseShred(["-n2", "z"]) == nil)
        expectParsed(
            parseShred(["--", "-n"]),
            "delete",
            paths: ["-n"]
        )
        expectParsed(
            parseFilesystemCommand(["shred", "secret"]),
            "delete",
            paths: ["secret"]
        )
        #expect(parseShred(["-n"]) == nil)
        #expect(parseShred(["-w", "file"]) == nil)
        #expect(parseShred(["--weird", "file"]) == nil)
        #expect(parseShred([]) == nil)
    }
}

private func expectParsed(
    _ parsed: ParsedFilesystemCommand?,
    _ operation: String,
    paths: [String],
    recursive: Bool = false,
    force: Bool = false,
    mode: String? = nil
) {
    guard let parsed else {
        Issue.record("expected \(operation) parse")
        return
    }
    #expect(operationName(parsed.operation) == operation)
    #expect(parsed.paths == paths)
    #expect(parsed.recursive == recursive)
    #expect(parsed.force == force)
    #expect(parsed.mode == mode)
}

private func operationName(_ operation: FilesystemOperation) -> String {
    switch operation {
    case .delete: return "delete"
    case .move: return "move"
    case .overwrite: return "overwrite"
    case .chmod: return "chmod"
    case .create: return "create"
    case .read: return "read"
    }
}
