import Foundation
import Synchronization
import Testing
import RVDomain
import RVHooks
import RVPolicy
import RVTheme
@testable import RVCLI

/// `rv try`: the words match the v2 "First run" frame, the stop is rv's
/// real verdict and hook text, and nothing outside its temp dir changes.
@Suite("rv try")
struct TryCommandTests {
    @Test("piped output is the v2 frame plus the agent's words, the ✓ and the next command")
    func pipedOutputIsExact() async throws {
        let sandbox = try TrySandbox()
        let run = await sandbox.runInProcess(palette: colorOffPalette, columns: 80)
        #expect(run.exitCode == 0)
        #expect(run.stderr == "")
        #expect(run.stdout == Self.expected)
    }

    @Test("nothing outside the temp dir changes: HOME, cwd and TMPDIR are as they were")
    func touchesNothingOutsideItsTempDir() async throws {
        let rv = try builtRV()
        let sandbox = try TrySandbox()
        let before = try sandbox.snapshot()

        let process = Process()
        process.executableURL = rv
        process.arguments = ["try"]
        process.currentDirectoryURL = sandbox.cwd
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": sandbox.home.path,
            "TMPDIR": sandbox.tmp.path,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "stderr: \(stderr)")
        #expect(stdout == Self.expected)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("in process, the temp dir is removed and HOME is untouched")
    func inProcessCleansUp() async throws {
        let sandbox = try TrySandbox()
        let before = try sandbox.snapshot()
        let run = await sandbox.runInProcess(palette: colorOffPalette, columns: 80)
        #expect(run.exitCode == 0)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("the stop is the verdict and hook text an agent gets for the same command")
    func stopMatchesTheHookText() async throws {
        let sandbox = try TryDemo.makeSandbox(in: try TrySandbox().tmp)
        defer { try? FileManager.default.removeItem(at: sandbox.root) }
        let command = ShellCommand(rawValue: "git reset --hard")
        let result = await CommandRun.evaluateCommand(
            command.rawValue,
            cwd: sandbox.repo.path,
            allowOnceDirectory: sandbox.home,
            home: nil
        )
        #expect(denyPayload(from: result.decision)?.ruleID.pattern == "reset-hard")
        let agentText = try #require(hostDenyText(from: result, command: command))
        #expect(await TryDemo.evaluate(in: sandbox) == .stopped(agentText: agentText))
    }

    @Test("every line fits 80 columns and a piped run has no escape codes")
    func fitsEightyColumns() async throws {
        let run = try await TrySandbox().runInProcess(palette: colorOffPalette, columns: 200)
        #expect(run.stdout.contains("\u{1B}") == false)
        for line in run.stdout.split(separator: "\n") {
            #expect(line.count <= 80, "too wide: \(line)")
        }
    }

    @Test("a narrow terminal wraps the agent's words under the command")
    func narrowTerminalWraps() async throws {
        let run = try await TrySandbox().runInProcess(palette: colorOffPalette, columns: 50)
        let hung = run.stdout.split(separator: "\n").filter { $0.hasPrefix(TryScreen.hang) }
        #expect(hung.count >= 4)
        for line in hung { #expect(line.count <= 50, "too wide: \(line)") }
    }

    @Test("colour only paints the glyph words, and the text reads the same without it")
    func colourIsInline() async throws {
        let painted = Palette(for: ColorCapability(colorsEnabled: true))
        let run = try await TrySandbox().runInProcess(palette: painted, columns: 80)
        #expect(run.stdout.contains("\(painted.deny)✕ Stopped\(painted.reset)"))
        #expect(run.stdout.contains("\(painted.allow)✓\(painted.reset) All 14 files are still here."))
        #expect(Self.stripANSI(run.stdout) == Self.expected)
    }

    @Test("numbers group by thousands without the locale")
    func grouping() {
        #expect(TryScreen.grouped(7) == "7")
        #expect(TryScreen.grouped(2314) == "2,314")
        #expect(TryScreen.grouped(1_234_567) == "1,234,567")
    }

    @Test("if rv lets the reset through, rv try says so and exits 1")
    func letThroughIsHonest() {
        let work = TryUnsavedWork(files: 14, lines: 2314)
        let lines = TryScreen.verdict(.letThrough, work: work, palette: colorOffPalette, columns: 80)
            + TryScreen.ending(.letThrough, intact: true, work: work, palette: colorOffPalette)
        #expect(lines.contains("  rv let git reset --hard through here. It did not run."))
        #expect(lines.contains { $0.contains("Quiet until it matters") } == false)
        #expect(lines.last == "  → rv doctor    find out why")
    }

    static let expected = """

      A throwaway repo with 14 unsaved files. Nothing real.

      agent › git reset --hard
      ✕ Stopped   git reset --hard
                  would discard 14 files · 2,314 lines
                  the agent read: “RV · Blocked. Destroys uncommitted changes. Use
                  'git stash' first.”

      ✓ All 14 files are still here.

      That's rv. Quiet until it matters.

      → rv doctor    check rv is guarding your agents

    """

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

/// Fresh HOME, cwd and TMPDIR, each with a file in it, to prove `rv try`
/// leaves them exactly as it found them.
private struct TrySandbox {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var cwd: URL { root.appendingPathComponent("cwd") }
    var tmp: URL { root.appendingPathComponent("tmp") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-try-test-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        for dir in [home, cwd, tmp, home.appendingPathComponent(".config/rv")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{}\n".utf8).write(to: home.appendingPathComponent(".config/rv/config.json"))
        try Data("mine\n".utf8).write(to: cwd.appendingPathComponent("notes.txt"))
        try Data("left here\n".utf8).write(to: tmp.appendingPathComponent("other.txt"))
    }

    /// Every path under the sandbox with its bytes and modification time.
    func snapshot() throws -> [String: String] {
        var entries: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return entries
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))
            let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if values.isDirectory == true {
                // TMPDIR's own mtime moves when rv try adds and removes its
                // dir there; what is inside it must not.
                entries[path] = path == "/tmp" ? "dir" : "dir \(stamp)"
            } else {
                let bytes = (try? Data(contentsOf: url)) ?? Data()
                entries[path] = "file \(stamp) \(bytes.base64EncodedString())"
            }
        }
        return entries
    }

    struct Run {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    func runInProcess(palette: Palette, columns: Int) async -> Run {
        let out = Mutex("")
        let err = Mutex("")
        let options = TryDemo.Options(
            tempRoot: tmp,
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": home.path],
            palette: palette,
            columns: columns,
            paced: false,
            write: { text in out.withLock { $0 += text } },
            writeError: { text in err.withLock { $0 += text } }
        )
        let context = CLIProcess.Context(home: HomeDirectory(validating: home.path), stdinIsTTY: false, stdoutIsTTY: false)
        let code = await CLIProcess.$context.withValue(context) {
            await TryDemo.run(options)
        }
        return Run(stdout: out.withLock { $0 }, stderr: err.withLock { $0 }, exitCode: code)
    }
}

/// The built `rv` executable next to the test bundle.
private func builtRV() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/rv"),
        root.appendingPathComponent(".build/debug/rv"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/rv"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent("rv"))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    let found = candidates.first { url in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
    return try #require(found, "missing built product rv")
}
