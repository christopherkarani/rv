#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Foundation
import RVDomain
import RVHistory
import RVHooks
import RVPolicy
import RVService
import RVTheme

/// `rv try`: a safe, fake disaster. A throwaway git repo with unsaved work,
/// a fake agent that tries `git reset --hard`, and rv stopping it.
///
/// The stop is real: the command goes through rv's in-process evaluate (the
/// gated peek `rv test` uses, as the agent's hook host) and the agent's
/// words are the hook deny text. Nothing else is: it never talks to rvd,
/// never reads or writes `~/.config/rv` (day-one policy, no home), never
/// runs the reset, and writes only inside one temp dir that it removes.
struct Try: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "try",
        abstract: "Watch rv stop a fake agent in a throwaway repo."
    )

    func run() async throws {
        let probe = ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        let palette = Palette(for: ColorCapability(probe: probe, mode: .pretty), background: probe.background)
        let options = TryDemo.Options(
            tempRoot: TryDemo.tempRoot(environment: CLIProcess.environment()),
            environment: CLIProcess.environment(),
            palette: palette,
            columns: probe.columns,
            paced: probe.stdoutIsTTY
        )
        let exitCode = await TryDemo.run(options, cleanupOnSignal: true)
        if exitCode != 0 { throw ExitCode(exitCode) }
    }
}

// MARK: - Screen (pure)

/// What the throwaway repo holds that `git reset --hard` would throw away.
struct TryUnsavedWork: Equatable, Sendable {
    var files: Int
    var lines: Int
}

/// What rv did with the fake agent's command.
enum TryVerdict: Equatable, Sendable {
    /// Stopped; the agent reads `agentText` (hook deny text).
    case stopped(agentText: String)
    /// rv let it through (it still never runs here).
    case letThrough
}

/// The words and layout of `rv try` (North Star v2, "First run").
/// Plain lines with palette inks; no width above `maxWidth`.
enum TryScreen {
    static let command = "git reset --hard"
    static let maxWidth = 80
    /// `  ✕ Stopped   ` is 14 columns; detail lines hang under the command.
    static let hang = String(repeating: " ", count: 14)
    static let next = CommandVocabulary.Command.doctor.invocation
    private typealias Glyph = CommandVocabulary.Glyph
    /// `✕ Stopped`: the command really did not run.
    static let stoppedLabel = "\(Glyph.stopped.rawValue) \(Glyph.stopped.word)"

    static func intro(_ work: TryUnsavedWork) -> [String] {
        ["", "  A throwaway repo with \(work.files) unsaved files. Nothing real.", ""]
    }

    static func agent(palette: Palette) -> [String] {
        ["  \(paint("agent ›", palette.trace, palette)) \(command)"]
    }

    static func verdict(_ verdict: TryVerdict, work: TryUnsavedWork, palette: Palette, columns: Int) -> [String] {
        switch verdict {
        case .stopped(let agentText):
            let width = min(max(columns, 40), maxWidth)
            let told = wrap("the agent read: “\(agentText)”", width: width - hang.count)
            return ["  \(paint(stoppedLabel, palette.deny, palette))   \(command)",
                    hang + paint("would discard \(files(work.files)) · \(grouped(work.lines)) lines", palette.muted, palette)]
                + told.map { hang + paint($0, palette.muted, palette) }
        case .letThrough:
            return ["  rv let \(command) through here. It did not run."]
        }
    }

    static func ending(_ verdict: TryVerdict, intact: Bool, work: TryUnsavedWork, palette: Palette) -> [String] {
        var lines: [String] = [""]
        if intact {
            lines.append("  \(paint(Glyph.done.rawValue, palette.allow, palette)) All \(files(work.files)) are still here.")
            lines.append("")
        }
        if case .stopped = verdict, intact {
            lines.append("  That's rv. Quiet until it matters.")
            lines.append("")
            lines.append("  \(paint("\(Glyph.next.rawValue) \(next)", palette.heading, palette))    check rv is guarding your agents")
        } else {
            lines.append("  \(paint("\(Glyph.next.rawValue) \(next)", palette.heading, palette))    find out why")
        }
        return lines
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// `2,314`: comma groups, independent of locale.
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    /// Greedy word wrap; a word longer than `width` gets its own line.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func paint(_ text: String, _ ink: String, _ palette: Palette) -> String {
        palette.colorsEnabled ? ink + text + palette.reset : text
    }
}

// MARK: - Demo (shell)

/// Builds the throwaway repo, asks rv about the fake agent's command,
/// checks the work is intact, prints the screen and removes the repo.
enum TryDemo {
    struct Options: Sendable {
        /// Parent of the one directory `rv try` creates (and removes).
        var tempRoot: URL
        /// The caller's environment; only `PATH` reaches git.
        var environment: [String: String]
        var palette: Palette
        var columns: Int
        /// Short pauses between beats on a terminal; never when piped.
        var paced: Bool
        var write: @Sendable (String) -> Void = { CommandContext.writeStdout($0) }
        var writeError: @Sendable (String) -> Void = { CommandContext.writeStderr($0) }
    }

    /// The one directory the run owns; the git repo is `repo/` inside it.
    struct Sandbox: Sendable {
        let root: URL
        var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
        /// Allow-once store and git's HOME: inside the sandbox, never `~`.
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    }

    /// `$TMPDIR` from the caller's environment, else the system temp dir.
    static func tempRoot(environment: [String: String]) -> URL {
        if let tmp = environment["TMPDIR"], tmp.hasPrefix("/") {
            return URL(fileURLWithPath: tmp, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// Exit code: 0 when rv stopped the reset and the work is intact.
    static func run(_ options: Options, cleanupOnSignal: Bool = false) async -> Int32 {
        let sandbox: Sandbox
        do {
            sandbox = try makeSandbox(in: options.tempRoot)
        } catch {
            options.writeError("rv try: could not make a temp dir in \(options.tempRoot.path): \(error.localizedDescription)\n")
            return 1
        }
        let guardSignals = cleanupOnSignal ? SignalCleanup(removing: sandbox.root) : nil
        defer {
            try? FileManager.default.removeItem(at: sandbox.root)
            guardSignals?.cancel()
        }

        let git: TryGit
        let work: TryUnsavedWork
        let written: [String: Data]
        do {
            git = try TryGit(sandbox: sandbox, environment: options.environment)
            written = try TryRepo.build(at: sandbox.repo, git: git)
            work = try TryRepo.unsavedWork(git: git)
        } catch {
            options.writeError("rv try: could not build the throwaway repo: \(error)\n")
            return 1
        }

        let palette = options.palette
        options.write(PrettyWriter.join(TryScreen.intro(work) + TryScreen.agent(palette: palette)))
        await pause(options, milliseconds: 500)

        let verdict = await evaluate(in: sandbox)
        options.write(PrettyWriter.join(
            TryScreen.verdict(verdict, work: work, palette: palette, columns: options.columns)
        ))
        await pause(options, milliseconds: 300)

        let intact = (try? TryRepo.isIntact(git: git, written: written, work: work)) ?? false
        options.write(PrettyWriter.join(TryScreen.ending(verdict, intact: intact, work: work, palette: palette)))

        if case .stopped = verdict, intact { return 0 }
        return 1
    }

    /// rv's in-process evaluate, as Claude Code's hook would ask it, with
    /// day-one policy (no home) and an allow-once store inside the sandbox.
    /// A peek: it records nothing and mints no code. Under observe it is the
    /// verdict guard mode would reach, which is what `rv try` shows.
    static func evaluate(in sandbox: Sandbox) async -> TryVerdict {
        let command = ShellCommand(rawValue: TryScreen.command)
        let world = LiveEvaluateWorld(
            home: nil,
            store: AllowOnceStore(baseDirectory: sandbox.home.appendingPathComponent(".config/rv", isDirectory: true))
        )
        let verdict = await world.peekVerdict(
            command: command,
            cwd: WorkingDirectory(validating: sandbox.repo.path),
            host: .hook(.claude)
        )
        guard let text = hostDenyText(from: verdict.shown, command: command) else { return .letThrough }
        return .stopped(agentText: text)
    }

    static func makeSandbox(in parent: URL) throws -> Sandbox {
        let root = parent.resolvingSymlinksInPath()
            .appendingPathComponent("rv-try-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let sandbox = Sandbox(root: root)
        try FileManager.default.createDirectory(at: sandbox.repo, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sandbox.home, withIntermediateDirectories: false)
        return sandbox
    }

    private static func pause(_ options: Options, milliseconds: UInt64) async {
        guard options.paced else { return }
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

/// The throwaway repo: 14 committed files, each with unsaved lines on top.
enum TryRepo {
    /// Path and how many unsaved lines it gets (2,314 in all).
    static let files: [(path: String, unsaved: Int)] = [
        ("src/app.ts", 412), ("src/routes.ts", 301), ("src/db.ts", 262), ("src/auth.ts", 220),
        ("src/cache.ts", 188), ("src/billing.ts", 171), ("src/search.ts", 154), ("src/email.ts", 139),
        ("src/jobs.ts", 121), ("src/config.ts", 104), ("test/app.test.ts", 87), ("test/billing.test.ts", 71),
        ("README.md", 52), ("NOTES.md", 32),
    ]

    /// Commits every file, then writes unsaved lines into each. Returns the
    /// bytes on disk per path, to check later that nothing changed.
    static func build(at repo: URL, git: TryGit) throws -> [String: Data] {
        try git.run(["init", "-q"])
        for (path, _) in files {
            try write(committed(path), to: repo.appendingPathComponent(path))
        }
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", "Start the app"])
        var written: [String: Data] = [:]
        for (path, count) in files {
            let data = Data((committed(path) + unsaved(path, count: count)).utf8)
            try write(data, to: repo.appendingPathComponent(path))
            written[path] = data
        }
        return written
    }

    /// What `git reset --hard` would discard, as git counts it.
    static func unsavedWork(git: TryGit) throws -> TryUnsavedWork {
        let rows = try git.output(["diff", "--numstat", "HEAD"])
            .split(separator: "\n")
            .map { $0.split(separator: "\t", maxSplits: 2) }
            .filter { $0.count == 3 }
        let lines = rows.reduce(0) { $0 + (Int($1[0]) ?? 0) + (Int($1[1]) ?? 0) }
        return TryUnsavedWork(files: rows.count, lines: lines)
    }

    /// Every file still holds exactly what was written, and git still sees
    /// the same unsaved work.
    static func isIntact(git: TryGit, written: [String: Data], work: TryUnsavedWork) throws -> Bool {
        for (path, data) in written {
            guard FileManager.default.contents(atPath: git.repo.appendingPathComponent(path).path) == data else {
                return false
            }
        }
        return try unsavedWork(git: git) == work
    }

    private static func committed(_ path: String) -> String {
        path.hasSuffix(".md") ? "# \(path)\n" : "// \(path)\nexport {}\n"
    }

    private static func unsaved(_ path: String, count: Int) -> String {
        let mark = path.hasSuffix(".md") ? "-" : "//"
        return (1...count).map { "\(mark) unsaved work, line \($0)\n" }.joined()
    }

    private static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

/// git, run in the throwaway repo with no user or system config, and HOME
/// and XDG dirs inside the sandbox, so it reads and writes nothing else.
struct TryGit: Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let executable: URL
    let repo: URL
    let environment: [String: String]

    init(sandbox: TryDemo.Sandbox, environment caller: [String: String]) throws {
        guard let found = Self.find(path: caller["PATH"] ?? "/usr/bin:/bin") else {
            throw Failure(description: "git is not on PATH")
        }
        executable = found
        repo = sandbox.repo
        environment = [
            "PATH": caller["PATH"] ?? "/usr/bin:/bin",
            "HOME": sandbox.home.path,
            "XDG_CONFIG_HOME": sandbox.home.appendingPathComponent(".config").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CEILING_DIRECTORIES": sandbox.root.path,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "rv try",
            "GIT_AUTHOR_EMAIL": "try@rv.invalid",
            "GIT_COMMITTER_NAME": "rv try",
            "GIT_COMMITTER_EMAIL": "try@rv.invalid",
            "LC_ALL": "C",
        ]
    }

    func run(_ arguments: [String]) throws {
        _ = try output(arguments)
    }

    func output(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
                             "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments
        process.currentDirectoryURL = repo
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "git \(arguments.first ?? "") failed: \(message)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func find(path: String) -> URL? {
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

/// Removes the sandbox if `rv try` is interrupted, then exits 130. A value
/// owned by `TryDemo.run` alone; the handlers capture only the sandbox URL.
private struct SignalCleanup {
    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private let sources: [any DispatchSourceSignal]

    init(removing root: URL) {
        sources = Self.signals.map { number in
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                try? FileManager.default.removeItem(at: root)
                exit(130)
            }
            source.resume()
            return source
        }
    }

    func cancel() {
        for source in sources { source.cancel() }
        for number in Self.signals { _ = signal(number, SIG_DFL) }
    }
}
