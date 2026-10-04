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
            parseTruncate(["--size=0", "-co", "x"]),
            "overwrite",
            paths: ["x"]
        )
        // `-r` takes the reference value: `-cor x` consumes `x`, leaving no
        // operand (the tool errors), while attached `-s0` reads size `0`.
        #expect(parseTruncate(["--size=0", "-cor", "x"]) == nil)
        expectParsed(
            parseTruncate(["-r", "ref", "y"]),
            "overwrite",
            paths: ["y"]
        )
        expectParsed(
            parseTruncate(["-s0", "y"]),
            "overwrite",
            paths: ["y"]
        )
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

    @Test func truncate_dashDashKeepsValueLongsVerbatim() {
        expectParsed(
            parseTruncate(["--", "--size", "10", "f"]),
            "overwrite",
            paths: ["--size", "10", "f"]
        )
    }

    @Test func splitFlagTerminator_routesValueTakingSpecsToPreSplit() {
        let spec = FlagValueSpec(valueLongs: ["size"])
        let (flags, rest) = splitFlagTerminator(
            Argv(program: "truncate", args: ["--", "--size", "10", "f"]),
            values: spec
        )
        #expect(flags.isEmpty)
        #expect(rest == ["--size", "10", "f"])
    }

    @Test func rm_dashDashKeepsEveryTokenShapeVerbatim() {
        expectParsed(
            parseRm(["--", "-", "--", "--long", "--long=value", "--empty=", "-xyz", "-n=v", "plain"]),
            "delete",
            paths: ["-", "--", "--long", "--long=value", "--empty=", "-xyz", "-n=v", "plain"]
        )
    }

    @Test func truncate_pendingValueConsumesDashDash() {
        expectParsed(
            parseTruncate(["-s", "--", "file"]),
            "overwrite",
            paths: ["file"]
        )
        expectParsed(
            parseTruncate(["--size", "--", "file"]),
            "overwrite",
            paths: ["file"]
        )
    }

    @Test func shred_pendingValueConsumesDashDash() {
        expectParsed(
            parseShred(["-n", "--", "file"]),
            "delete",
            paths: ["file"]
        )
        expectParsed(
            parseShred(["--size", "--", "file"]),
            "delete",
            paths: ["file"]
        )
    }

    @Test func shred_dashDashKeepsValueLongsVerbatim() {
        expectParsed(
            parseShred(["--", "--size", "10", "f"]),
            "delete",
            paths: ["--size", "10", "f"]
        )
        expectParsed(
            parseShred(["--", "--iterations", "3", "g"]),
            "delete",
            paths: ["--iterations", "3", "g"]
        )
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
        // Attached `-n2` reads iterations `2`, exactly like the tool.
        expectParsed(
            parseShred(["-n2", "z"]),
            "delete",
            paths: ["z"]
        )
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

    @Test func rm_newShortsAndAbbreviations() {
        expectParsed(parseRm(["-W", "a"]), "delete", paths: ["a"])
        expectParsed(parseRm(["-x", "a"]), "delete", paths: ["a"])
        expectParsed(parseRm(["-P", "a"]), "delete", paths: ["a"])
        expectParsed(
            parseRm(["--rec", "a"]),
            "delete",
            paths: ["a"],
            recursive: true
        )
        expectParsed(
            parseRm(["--r", "a"]),
            "delete",
            paths: ["a"],
            recursive: true
        )
        expectParsed(parseRm(["--inter=never", "a"]), "delete", paths: ["a"])
        expectParsed(parseRm(["--one", "a"]), "delete", paths: ["a"])
        expectParsed(parseRm(["--no-", "a"]), "delete", paths: ["a"])
        // Post-`--` words recover verbatim, never resolved.
        expectParsed(parseRm(["--", "--rec"]), "delete", paths: ["--rec"])
        // Ambiguous abbreviations stay unknown (the tool errors).
        #expect(parseRm(["--d", "a"]) == nil)
    }

    @Test func mv_suffixAndTargetDirectory() {
        expectParsed(parseMv(["-S", "suf", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(parseMv(["-Ssuf", "a", "b"]), "move", paths: ["a", "b"])
        // `-S` blocks the pre-scan `-t`: suffix reads `tDIR`.
        expectParsed(parseMv(["-StDIR", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(parseMv(["-h", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(parseMv(["-b", "-T", "-Z", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(
            parseMv(["--targ", "/tmp/t", "a", "b"]),
            "move",
            paths: ["/tmp/t", "a", "b"]
        )
        expectParsed(
            parseMv(["-t", "/tmp/a", "--targ", "/tmp/b", "x"]),
            "move",
            paths: ["/tmp/b", "x", "/tmp/a"]
        )
        expectParsed(parseMv(["--suf", "x", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(
            parseMv(["--strip-trailing-slashes", "a", "b"]),
            "move",
            paths: ["a", "b"]
        )
        expectParsed(parseMv(["--backup", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(parseMv(["--backup=x", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(parseMv(["--context=x", "a", "b"]), "move", paths: ["a", "b"])
        expectParsed(
            parseMv(["--no-target-directory", "a", "b"]),
            "move",
            paths: ["a", "b"]
        )
        #expect(parseMv(["-S"]) == nil)
    }

    @Test func rmdir_abbreviations() {
        expectParsed(parseRmdir(["--par", "a"]), "delete", paths: ["a"])
        expectParsed(parseRmdir(["--i", "a"]), "delete", paths: ["a"])
        #expect(parseRmdir(["--x", "a"]) == nil)
    }

    @Test func truncate_referenceFlags() {
        expectParsed(parseTruncate(["-r", "ref", "f"]), "overwrite", paths: ["f"])
        expectParsed(
            parseTruncate(["--reference=ref", "f"]),
            "overwrite",
            paths: ["f"]
        )
        expectParsed(parseTruncate(["--ref", "ref", "f"]), "overwrite", paths: ["f"])
        expectParsed(parseTruncate(["--no-c", "f"]), "overwrite", paths: ["f"])
    }

    @Test func shred_randomSource() {
        expectParsed(
            parseShred(["--random-source=/dev/urandom", "f"]),
            "delete",
            paths: ["f"]
        )
        expectParsed(parseShred(["--ra", "r", "f"]), "delete", paths: ["f"])
        expectParsed(parseShred(["--re", "f"]), "delete", paths: ["f"])
        // `--r` is ambiguous (`remove`/`random-source`): the tool errors.
        #expect(parseShred(["--r", "f"]) == nil)
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
