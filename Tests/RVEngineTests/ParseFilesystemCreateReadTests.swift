import Testing
import RVDomain
@testable import RVEngine

@Suite("Parse filesystem create/read")
struct ParseFilesystemCreateReadTests {
    @Test func chmod_modeledFlagsAndDashDash() {
        expectParsed(
            parseChmod(["--recursive", "--verbose", "755", "file"]),
            "chmod",
            paths: ["file"],
            recursive: true,
            mode: "755"
        )
        expectParsed(
            parseChmod(["-Rfvch", "u+x", "bin"]),
            "chmod",
            paths: ["bin"],
            recursive: true,
            mode: "u+x"
        )
        expectParsed(
            parseChmod(["--", "0755", "a", "b"]),
            "chmod",
            paths: ["a", "b"],
            mode: "0755"
        )
        expectParsed(
            parseChmod(["g=r", "--", "-weird"]),
            "chmod",
            paths: ["-weird"],
            mode: "g=r"
        )
        expectParsed(
            parseFilesystemCommand(["/bin/chmod", "--silent", "--quiet", "--changes", "--no-dereference", "644", "x"]),
            "chmod",
            paths: ["x"],
            mode: "644"
        )
    }

    @Test func chmod_rejectsUnknownAndIncomplete() {
        #expect(parseChmod(["-Z", "755", "file"]) == nil)
        #expect(parseChmod(["--unknown", "755", "file"]) == nil)
        #expect(parseChmod(["755"]) == nil)
        #expect(parseChmod(["file"]) == nil)
        #expect(parseChmod(["888", "file"]) == nil)
        #expect(parseChmod(["12", "file"]) == nil)
        #expect(parseChmod(["--", "not-a-mode"]) == nil)
        #expect(parseChmod(["--", "nota", "file"]) == nil)
        #expect(parseChmod([]) == nil)
        #expect(isChmodMode("755"))
        #expect(isChmodMode("0755"))
        #expect(isChmodMode("a-w"))
        #expect(isChmodMode("75") == false)
        #expect(isChmodMode("12345") == false)
        #expect(isChmodMode("file") == false)
    }

    @Test func touch_modeledFlagsAndValueOptions() {
        expectParsed(
            parseTouch(["-acfh", "--no-create", "--date=now", "--time=midnight", "a", "b"]),
            "create",
            paths: ["a", "b"]
        )
        expectParsed(
            parseTouch(["-t", "202001010000", "-d", "now", "file"]),
            "create",
            paths: ["file"]
        )
        expectParsed(
            parseTouch(["--date", "now", "--time", "noon", "--no-dereference", "--help", "--version", "x"]),
            "create",
            paths: ["x"]
        )
        expectParsed(
            parseTouch(["--", "-n", "file"]),
            "create",
            paths: ["-n", "file"]
        )
        expectParsed(
            parseFilesystemCommand(["touch", "new.swift"]),
            "create",
            paths: ["new.swift"]
        )
    }

    @Test func touch_dashDashKeepsValueLongsVerbatim() {
        expectParsed(
            parseTouch(["--", "--date", "now", "f"]),
            "create",
            paths: ["--date", "now", "f"]
        )
        expectParsed(
            parseTouch(["--", "--time", "noon", "g"]),
            "create",
            paths: ["--time", "noon", "g"]
        )
    }

    @Test func touch_pendingValueConsumesDashDash() {
        expectParsed(
            parseTouch(["-t", "--", "file"]),
            "create",
            paths: ["file"]
        )
        expectParsed(
            parseTouch(["--date", "--", "file"]),
            "create",
            paths: ["file"]
        )
    }

    @Test func touch_rejectsUnknownAndDanglingValue() {
        #expect(parseTouch(["-z", "file"]) == nil)
        #expect(parseTouch(["--weird", "file"]) == nil)
        #expect(parseTouch(["-t"]) == nil)
        #expect(parseTouch(["-acfhmd"]) == nil)
        #expect(parseTouch([]) == nil)
        #expect(parseTouch(["-t", "stamp"]) == nil)
    }

    @Test func mkdir_modeledFlagsAndMode() {
        expectParsed(
            parseMkdir(["-pv", "--parents", "--verbose", "--help", "--version", "dir"]),
            "create",
            paths: ["dir"]
        )
        expectParsed(
            parseMkdir(["-m", "755", "--mode", "700", "nested"]),
            "create",
            paths: ["nested"]
        )
        expectParsed(
            parseMkdir(["--mode=755", "x"]),
            "create",
            paths: ["x"]
        )
        expectParsed(
            parseMkdir(["--", "-p"]),
            "create",
            paths: ["-p"]
        )
        expectParsed(
            parseFilesystemCommand(["mkdir", "out"]),
            "create",
            paths: ["out"]
        )
    }

    @Test func mkdir_dashDashKeepsValueLongsVerbatim() {
        expectParsed(
            parseMkdir(["--", "--mode", "755", "d"]),
            "create",
            paths: ["--mode", "755", "d"]
        )
    }

    @Test func mkdir_rejectsUnknownAndDanglingMode() {
        #expect(parseMkdir(["-z", "dir"]) == nil)
        #expect(parseMkdir(["--weird", "dir"]) == nil)
        #expect(parseMkdir(["-m"]) == nil)
        #expect(parseMkdir(["-pm"]) == nil)
        #expect(parseMkdir([]) == nil)
    }

    @Test func cat_modeledFlagsAndRead() {
        expectParsed(
            parseCat(["-AbEenstTuv", "--show-all", "--number-nonblank", "--show-ends", "file"]),
            "read",
            paths: ["file"]
        )
        expectParsed(
            parseCat(["--number", "--squeeze-blank", "--show-tabs", "--show-nonprinting", "--help", "--version", "a", "b"]),
            "read",
            paths: ["a", "b"]
        )
        expectParsed(
            parseCat(["--", "-n"]),
            "read",
            paths: ["-n"]
        )
        expectParsed(
            parseFilesystemCommand(["/usr/bin/cat", "Sources/Foo.swift"]),
            "read",
            paths: ["Sources/Foo.swift"]
        )
    }

    @Test func cat_rejectsUnknownAndEmpty() {
        #expect(parseCat(["-q", "file"]) == nil)
        #expect(parseCat(["--weird", "file"]) == nil)
        #expect(parseCat([]) == nil)
    }

    @Test func catWithRedirect_isOverwriteNotRead() {
        expectParsed(
            parseFilesystemCommand(["cat", "src", ">", "dest"]),
            "overwrite",
            paths: ["dest"]
        )
    }

    @Test func redirectOnly_operatorsAttachedAndFdDup() {
        #expect(isRedirectOperator(">"))
        #expect(isRedirectOperator(">|"))
        #expect(isRedirectOperator(">>"))
        #expect(isRedirectOperator("&>"))
        #expect(isRedirectOperator("1>"))
        #expect(isRedirectOperator("2>"))
        #expect(isFdDup("2>&1"))
        #expect(isFdDup("1>&2"))
        #expect(isFdDup(">&1"))
        #expect(isFdDup(">&2"))

        expectParsed(
            parseRedirectOnly(["echo", "hi", ">", "a", ">>", "b", ">|", "c"]),
            "overwrite",
            paths: ["a", "b", "c"]
        )
        expectParsed(
            parseRedirectOnly(["echo", "hi", "&>", "both", "1>", "out", "2>", "err"]),
            "overwrite",
            paths: ["both", "out", "err"]
        )
        expectParsed(
            parseRedirectOnly(["echo", "hi", "2>&1", ">", "kept"]),
            "overwrite",
            paths: ["kept"]
        )
        expectParsed(
            parseRedirectOnly(["echo", "hi", ">", "&1", ">>file"]),
            "overwrite",
            paths: ["file"]
        )
        expectParsed(
            parseRedirectOnly(["true", ">|file", "&>log", "1>stdout", "2>stderr", ">plain"]),
            "overwrite",
            paths: ["file", "log", "stdout", "stderr", "plain"]
        )
        expectParsed(
            parseFilesystemCommand(["echo", "hi", ">", "$HOME/.ssh/config"]),
            "overwrite",
            paths: ["$HOME/.ssh/config"]
        )
        expectParsed(
            parseFilesystemCommand(["echo", "hi", ">", "~/out"]),
            "overwrite",
            paths: ["~/out"]
        )
    }

    @Test func redirectOnly_rejectsDynamicMissingAndNonRedirect() {
        #expect(parseRedirectOnly(["echo", "hi", ">"]) == nil)
        #expect(parseRedirectOnly(["echo", "hi", ">", "$FILE"]) == nil)
        #expect(parseRedirectOnly(["echo", "hi", ">", "`cmd`"]) == nil)
        #expect(parseRedirectOnly(["echo", ">>$FILE"]) == nil)
        #expect(parseRedirectOnly(["echo", ">`cmd`"]) == nil)
        #expect(parseRedirectOnly(["echo", "hi", "2>&1"]) == nil)
        #expect(parseRedirectOnly(["echo", "hi"]) == nil)
        #expect(parseRedirectOnly(["echo", "&>&1"]) == nil)
        #expect(parseRedirectOnly(["echo", "1>&2"]) == nil)
        #expect(parseRedirectOnly(["echo", "2>&1"]) == nil)
        #expect(parseRedirectOnly(["echo", "1>&3"]) == nil)
        #expect(parseRedirectOnly(["echo", "2>&9"]) == nil)
        #expect(parseRedirectOnly(["echo", "&>&x"]) == nil)
        #expect(parseRedirectOnly(["echo", ">&1"]) == nil)
        #expect(parseFilesystemCommand([]) == nil)
        #expect(parseFilesystemCommand(["echo", "hello"]) == nil)
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
