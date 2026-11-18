import Foundation
import RVDomain
import Testing
@testable import RVMCP

/// `sandbox-exec` rejects any one string literal longer than 1023 bytes with
/// "Error reading string". A case-folded deny regex is ~7 bytes per letter,
/// so a home path of ~60 letters used to make every caged server fail.
@Suite("MCPSandbox long paths")
struct MCPSandboxLongPathTests {
    static let readerLimit = 1023

    /// Every `"..."` and `#"..."` literal in a profile, as written.
    static func literals(in profile: String) -> [String] {
        var found: [String] = []
        let scalars = Array(profile.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\"" else {
                index += 1
                continue
            }
            var body = ""
            index += 1
            while index < scalars.count, scalars[index] != "\"" {
                if scalars[index] == "\\", index + 1 < scalars.count {
                    body.unicodeScalars.append(scalars[index])
                    index += 1
                }
                body.unicodeScalars.append(scalars[index])
                index += 1
            }
            found.append(body)
            index += 1
        }
        return found
    }

    static func longestLiteral(in profile: String) -> Int {
        literals(in: profile).map(\.utf8.count).max() ?? 0
    }

    /// 200 letters in one component: under NAME_MAX, far over the reader limit once folded.
    static let letterHeavy = String(repeating: "Abcdefghij", count: 20)

    @Test func seatbeltStringSplitsWithoutBreakingAnEscape() {
        let escaped = String(repeating: #"[Aa]ſ?\.\"\\"#, count: 400)
        let emitted = MCPSandbox.seatbeltString(escaped, raw: true)
        #expect(emitted.hasPrefix("(string-append #\""))
        let parts = Self.literals(in: emitted)
        #expect(parts.count > 1)
        #expect(parts.joined() == escaped)
        for part in parts {
            #expect(part.utf8.count <= MCPSandbox.seatbeltLiteralBytes)
            var trailing = 0
            for scalar in part.unicodeScalars.reversed() {
                guard scalar == "\\" else { break }
                trailing += 1
            }
            #expect(trailing % 2 == 0, "chunk ends inside an escape")
        }
        #expect(MCPSandbox.seatbeltString("/short", raw: false) == "\"/short\"")
        #expect(MCPSandbox.seatbeltString("^/x$", raw: true) == "#\"^/x$\"")
    }

    @Test func pathMaxDenyStaysUnderTheReaderLimitAndCompiles() throws {
        // 1023 bytes: PATH_MAX less the NUL. Mixed case and Unicode that folds wide.
        var path = "/Users"
        while path.utf8.count < 1000 {
            path += "/" + String("Straße-ΣIGMA-ﬁle-\(Self.letterHeavy)".prefix(200))
        }
        while path.utf8.count < 1023 { path += "x" }
        // This path has no symlink, so it emits no openings (those need a real
        // link to redirect a missing name) and a write root would not change
        // the output: it covers the deny literals. The next test covers the
        // openings.
        let filters = MCPSandbox.paths([path], denyTargets: true, writable: [])
        let profile = "(version 1)(allow default)(deny file-read* " + filters + ")"
        #expect(Self.longestLiteral(in: profile) <= MCPSandbox.seatbeltLiteralBytes)
        #expect(MCPSandbox.seatbeltLiteralBytes < Self.readerLimit)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(profile) == nil)
        #endif
    }

    /// A credential path that crosses a real symlink to a letter-heavy
    /// directory, with a letter-heavy name missing after it, inside a write
    /// root: `symlinkOpenings` emits openings (only with the write root, where
    /// the cage could create the name), and every literal they add, folded
    /// past the reader limit, is still chunked under it and compiles.
    @Test(.timeLimit(.minutes(1))) func symlinkOpeningsStayUnderTheReaderLimitAndCompile() throws {
        let root = URL(fileURLWithPath: MCPSandbox.realPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("rv-open-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(Self.letterHeavy, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let path = link.appendingPathComponent("Q\(Self.letterHeavy)").appendingPathComponent("key").path

        let openings = MCPSandbox.missingSymlinkOpenings(path)
        #expect(openings.isEmpty == false, "no openings for \(path)")
        #expect(openings.contains { $0.contains(Self.letterHeavy) })
        let filters = MCPSandbox.paths([path], denyTargets: true, writable: [root.path])
        #expect(filters.utf8.count > MCPSandbox.paths([path], denyTargets: true, writable: []).utf8.count,
                "the write root should add the openings")
        let profile = "(version 1)(allow default)(deny file-read* " + filters + ")"
        #expect(profile.contains("(string-append"))
        #expect(Self.longestLiteral(in: profile) <= MCPSandbox.seatbeltLiteralBytes)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(profile) == nil)
        #endif
    }

    @Test func profileForALetterHeavyHomeKeepsEveryLiteralUnderTheLimit() throws {
        // The resolved temp root: /var/folders is /private/var/folders.
        let root = URL(fileURLWithPath: MCPSandbox.realPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("rv-long-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent(Self.letterHeavy).appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/long", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: config.path, temporaryDirectory: NSTemporaryDirectory()).get()
        #expect(text.contains("(string-append"))
        #expect(Self.longestLiteral(in: text) <= MCPSandbox.seatbeltLiteralBytes)
        #if os(macOS)
        #expect(MCPSandbox.profileCompileError(text) == nil)
        #endif
    }

    #if os(macOS)
    @Test func compileErrorIsReportedBeforeLaunch() {
        let reason = MCPSandbox.profileCompileError("(version 1)(allow default)(deny file-read* (subpath \"/\(String(repeating: "a", count: 1100))\"))")
        #expect(reason?.contains("Error reading string") == true)
        let message = MCPSandbox.profileFailure(server: "gh", reason: "Error reading string").message
        #expect(message.contains("could not build the sandbox profile for MCP server gh: Error reading string"))
        #expect(MCPSandbox.profileCompileError("(version 1)(allow default)") == nil)
    }

    /// Live: a home whose credential paths fold far past the reader limit
    /// still starts the server and still denies the credential. The home is a
    /// fresh 0700 directory under `/Users/Shared`, named with the letter-heavy
    /// component so the credential literals still fold past the reader limit;
    /// a real home is not needed, only a long path component no profile line
    /// names. A UUID per run (250 bytes in all, under NAME_MAX) keeps two
    /// test processes from sharing or removing each other's directory.
    @Test(.enabled(if: FileManager.default.isWritableFile(atPath: "/Users/Shared"), "needs a writable /Users/Shared outside the cage's write roots"))
    func cagedServerWithALetterHeavyHomeStartsAndStillDeniesCredentials() throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-long-\(Self.letterHeavy)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        let brave = home.appendingPathComponent("Library/Application Support/BraveSoftware")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)
        try Data("PRIVATE".utf8).write(to: brave.appendingPathComponent("Cookies"))
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/long", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: config.path, temporaryDirectory: NSTemporaryDirectory()).get()

        let script = """
            cat '\(brave.path)/Cookies' >/dev/null 2>&1 && echo READ_COOKIES
            echo started
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPSandbox.sandboxExec)
        process.arguments = ["-p", text, "/bin/sh", "-c", script]
        process.currentDirectoryURL = scratch
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("started"), "\(errors)")
        #expect(output.contains("READ_COOKIES") == false)
    }
    #endif
}
