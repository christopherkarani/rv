#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import Testing
import RVDomain
import RVHooks
import RVPolicy
import RVTheme
@testable import RVCLI

/// `rv try`: the words match the v2 "First run" frame, the stop is rv's
/// real verdict and Claude Code's real guard mode, and nothing outside its
/// temp dir changes, however the run ends.
@Suite("rv try")
struct TryCommandTests {
    @Test("guarded, piped output is the v2 frame line for line")
    func pipedOutputIsTheFrame() async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let run = await sandbox.runInProcess(guardMode: .enforce)
        #expect(run.exitCode == 0)
        #expect(run.stderr == "")
        #expect(run.stdout == Self.stopped)
    }

    @Test("in watch mode it says the reset would run, names the guard command and exits 1")
    func watchModeIsHonest() async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let run = await sandbox.runInProcess(guardMode: .observe)
        #expect(run.exitCode == 1)
        #expect(run.stdout == Self.watched)
    }

    @Test("Claude Code's mode comes from config.json, the environment can only tighten it")
    func readsClaudeGuardMode() throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let home = try #require(HomeDirectory(validating: sandbox.home.path))
        #expect(TryDemo.claudeGuardMode(home: home, environment: [:]) == .enforce)
        #expect(TryDemo.claudeGuardMode(home: nil, environment: [:]) == .enforce)
        try sandbox.writeConfig(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        #expect(TryDemo.claudeGuardMode(home: home, environment: [:]) == .observe)
        #expect(TryDemo.claudeGuardMode(home: home, environment: ["RV_GUARD_MODE": "enforce"]) == .enforce)
        try sandbox.writeConfig(#"{"guard":{"mode":"observe","hosts":{"claude":"block"}}}"#)
        #expect(TryDemo.claudeGuardMode(home: home, environment: [:]) == .enforce)
        try sandbox.writeConfig(#"{"guard":{"mode":"observe"}}"#)
        #expect(TryDemo.claudeGuardMode(home: home, environment: [:]) == .observe)
    }

    @Test("the binary changes nothing outside its temp dir: HOME, cwd and TMPDIR are as they were")
    func touchesNothingOutsideItsTempDir() throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let before = try sandbox.snapshot()
        let run = try sandbox.runBinary()
        #expect(run.exitCode == 0, "stderr: \(run.stderr)")
        #expect(run.stdout == Self.stopped)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("the binary reads a watch-mode config without writing to it")
    func binaryHonoursWatchMode() throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        try sandbox.writeConfig(#"{"guard":{"hosts":{"claude":"observe"}}}"#)
        let before = try sandbox.snapshot()
        let run = try sandbox.runBinary()
        #expect(run.exitCode == 1, "stderr: \(run.stderr)")
        #expect(run.stdout == Self.watched)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("a closed pipe kills rv try without leaving its temp dir behind")
    func closedPipeLeavesNothing() throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let before = try sandbox.snapshot()
        _ = try sandbox.runBinary(closeStdout: true)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("SIGTERM mid-run leaves nothing behind", arguments: [0, 50, 150, 300])
    func signalLeavesNothing(afterMilliseconds delay: Int) throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let before = try sandbox.snapshot()
        _ = try sandbox.runBinary(signalAfter: delay)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("in process, the temp dir is removed and HOME is untouched")
    func inProcessCleansUp() async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let before = try sandbox.snapshot()
        let run = await sandbox.runInProcess(guardMode: .enforce)
        #expect(run.exitCode == 0)
        #expect(try sandbox.snapshot() == before)
    }

    @Test("rv's verdict is the deny the hook would send for the same command")
    func verdictMatchesTheHook() async throws {
        let parent = try TrySandbox()
        defer { parent.remove() }
        let sandbox = try TryDemo.makeSandbox(in: parent.tmp)
        let command = ShellCommand(rawValue: TryScreen.command)
        let result = await CommandRun.evaluateCommand(
            command.rawValue,
            cwd: sandbox.repo.path,
            allowOnceDirectory: sandbox.home,
            home: nil
        )
        #expect(denyPayload(from: result.decision)?.ruleID.pattern == "reset-hard")
        #expect(hostDenyText(from: result, command: command) != nil)
        #expect(await TryDemo.deniedByRV(in: sandbox))
    }

    @Test("every line fits the terminal, at most 80 columns, with no escape codes when piped",
          arguments: [200, 80, 40])
    func fitsTheTerminal(columns: Int) async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        for mode in [GuardMode.enforce, .observe] {
            let run = await sandbox.runInProcess(guardMode: mode, columns: columns)
            #expect(run.stdout.contains("\u{1B}") == false)
            for line in run.stdout.split(separator: "\n") {
                #expect(line.count <= min(columns, 80), "\(mode) too wide at \(columns): \(line)")
            }
        }
    }

    @Test("at 40 columns the long lines wrap and the words stay in order")
    func fortyColumnsWrap() async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let run = await sandbox.runInProcess(guardMode: .enforce, columns: 40)
        #expect(run.stdout.contains("  A throwaway repo with 14 unsaved\n  files. Nothing real.\n"))
        #expect(run.stdout.contains("              would discard 14 files ·\n              2,314 lines\n"))
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        #expect(words(run.stdout) == words(Self.stopped))
    }

    @Test("colour only paints the glyph words, and the text reads the same without it")
    func colourIsInline() async throws {
        let sandbox = try TrySandbox()
        defer { sandbox.remove() }
        let painted = Palette(for: ColorCapability(colorsEnabled: true))
        let run = await sandbox.runInProcess(guardMode: .enforce, palette: painted)
        #expect(run.stdout.contains("\(painted.deny)✕ Stopped\(painted.reset)"))
        #expect(Self.stripANSI(run.stdout) == Self.stopped)
        let watched = await sandbox.runInProcess(guardMode: .observe, palette: painted)
        #expect(Self.stripANSI(watched.stdout) == Self.watched)
    }

    @Test("numbers group by thousands without the locale")
    func grouping() {
        #expect(TryScreen.grouped(7) == "7")
        #expect(TryScreen.grouped(2314) == "2,314")
        #expect(TryScreen.grouped(1_234_567) == "1,234,567")
    }

    @Test("if rv let the reset through, rv try says so")
    func letThroughIsHonest() {
        let work = TryUnsavedWork(files: 14, lines: 2314)
        let lines = TryScreen.lines(.letThrough, work: work, palette: colorOffPalette, columns: 80).stop
        #expect(lines == ["  rv let git reset --hard through. It did not run here.", "", "  → rv doctor    find out why"])
    }

    /// v2 Reimagined, "First run" (`$ rv try`), without the prompt line.
    static let stopped = """

      A throwaway repo with 14 unsaved files. Nothing real.

      agent › git reset --hard
      ✕ Stopped   git reset --hard
                  would discard 14 files · 2,314 lines

      That's rv. Quiet until it matters.

    """

    /// The frame's honest form when Claude Code is in watch mode.
    static let watched = """

      A throwaway repo with 14 unsaved files. Nothing real.

      agent › git reset --hard
      ◐ Would stop  git reset --hard
                    would discard 14 files · 2,314 lines

      → rv guard claude    stop it for real

    """

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

/// Fresh HOME, cwd and TMPDIR, each with a file in it, to prove `rv try`
/// leaves them exactly as it found them. `remove()` deletes it all.
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
        try writeConfig("{}\n")
        try Data("mine\n".utf8).write(to: cwd.appendingPathComponent("notes.txt"))
        try Data("left here\n".utf8).write(to: tmp.appendingPathComponent("other.txt"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: home.appendingPathComponent(".config/rv/config.json"))
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

    func runInProcess(
        guardMode: GuardMode, palette: Palette = colorOffPalette, columns: Int = 80
    ) async -> Run {
        let out = Mutex("")
        let err = Mutex("")
        let options = TryDemo.Options(
            tempRoot: tmp,
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": home.path],
            guardMode: guardMode,
            palette: palette,
            columns: columns,
            paced: false,
            write: { text in out.withLock { $0 += text } },
            writeError: { text in err.withLock { $0 += text } }
        )
        let code = await TryDemo.run(options)
        return Run(stdout: out.withLock { $0 }, stderr: err.withLock { $0 }, exitCode: code)
    }

    /// The built `rv try`, with HOME, cwd and TMPDIR inside the sandbox.
    /// `closeStdout` closes the pipe's read end first (SIGPIPE on the first
    /// write); `signalAfter` sends SIGTERM that many milliseconds in.
    func runBinary(closeStdout: Bool = false, signalAfter delay: Int? = nil) throws -> Run {
        let process = Process()
        process.executableURL = try builtRV()
        process.arguments = ["try"]
        process.currentDirectoryURL = cwd
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path,
            "TMPDIR": tmp.path,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        if closeStdout { try out.fileHandleForReading.close() }
        if let delay {
            usleep(UInt32(delay) * 1000)
            kill(process.processIdentifier, SIGTERM)
        }
        let errors = Mutex(Data())
        let drained = DispatchGroup()
        drained.enter()
        // Its own thread, not a global queue: parallel cases block every
        // cooperative thread here, and global queues then get no thread.
        Thread.detachNewThread {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errors.withLock { $0 = data }
            drained.leave()
        }
        let stdout = closeStdout ? Data() : out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return Run(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: errors.withLock { String(decoding: $0, as: UTF8.self) },
            exitCode: process.terminationStatus
        )
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
