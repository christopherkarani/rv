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
import Synchronization

/// `rv try`: a safe, fake disaster. A throwaway git repo with unsaved work,
/// a fake agent that tries `git reset --hard`, and rv stopping it.
///
/// The verdict is real: the command goes through rv's in-process evaluate
/// (the gated peek `rv test` uses, as Claude Code's hook host, day-one
/// policy) and counts as stopped when the hook would send a deny. Whether
/// a real agent's reset would be stopped also depends on Claude Code's
/// guard mode, read from `~/.config/rv/config.json` the way `rv host list`
/// reads it; under watch (observe) mode the screen says it would stop.
///
/// Nothing else is real: it never talks to rvd, never writes outside one
/// temp dir, never runs the reset, and removes the temp dir before it
/// prints, so a closed pipe or a signal cannot leave it behind.
struct Try: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "try",
        abstract: "Watch rv stop a fake agent in a throwaway repo."
    )

    func run() async throws {
        let probe = ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        let environment = CLIProcess.environment()
        let home = CLIProcess.home()
        let guardMode = (try? await BlockingIO.run { TryDemo.claudeGuardMode(home: home, environment: environment) })
            ?? .enforce
        let options = TryDemo.Options(
            tempRoot: TryDemo.tempRoot(environment: environment),
            environment: environment,
            guardMode: guardMode,
            palette: Palette(for: ColorCapability(probe: probe, mode: .pretty), background: probe.background),
            columns: probe.columns,
            paced: probe.stdoutIsTTY,
            catchesSignals: true
        )
        let exitCode = await TryDemo.run(options)
        if exitCode != 0 { throw ExitCode(exitCode) }
    }
}

// MARK: - Screen (pure)

/// What the throwaway repo holds that `git reset --hard` would throw away.
struct TryUnsavedWork: Equatable, Sendable {
    var files: Int
    var lines: Int
}

/// What a real agent's `git reset --hard` would meet.
enum TryOutcome: Equatable, Sendable {
    /// rv denies it and Claude Code is guarded: stopped.
    case stopped
    /// rv denies it, but Claude Code is in watch mode: it would run.
    case wouldStop
    /// rv lets it through (it still never runs here).
    case letThrough
}

/// The words and layout of `rv try`: the v2 "First run" frame, line for
/// line, under guard mode. Plain lines with palette inks, wrapped to the
/// terminal and never wider than `maxWidth`.
enum TryScreen {
    private typealias Glyph = CommandVocabulary.Glyph

    static let command = "git reset --hard"
    static let maxWidth = 80
    /// `✕ Stopped`: the command really did not run.
    static let stoppedLabel = "\(Glyph.stopped.rawValue) \(Glyph.stopped.word)"
    /// `◐ Would stop`: watch mode would let it run.
    static let wouldStopLabel = "\(Glyph.watched.rawValue) Would stop"
    /// Puts Claude Code in guard mode.
    static let guardClaude = "\(CommandVocabulary.Alias.guard.invocation) \(HookHost.claude.rawValue)"
    static let doctor = CommandVocabulary.Command.doctor.invocation

    static func lines(
        _ outcome: TryOutcome, work: TryUnsavedWork, palette: Palette, columns: Int
    ) -> (intro: [String], stop: [String]) {
        let width = min(columns, maxWidth)
        let intro = [""]
            + wrap("A throwaway repo with \(work.files) unsaved \(work.files == 1 ? "file" : "files"). Nothing real.", indent: "  ", width: width)
            + ["", "  \(paint("agent ›", palette.trace, palette)) \(command)"]
        return (intro, verdict(outcome, work: work, palette: palette, width: width))
    }

    private static func verdict(_ outcome: TryOutcome, work: TryUnsavedWork, palette: Palette, width: Int) -> [String] {
        let discard = "would discard \(files(work.files)) · \(grouped(work.lines)) lines"
        switch outcome {
        case .stopped:
            return stop(stoppedLabel, ink: palette.deny, detail: discard, palette: palette, width: width)
                + ["", "  That's rv. Quiet until it matters."]
        case .wouldStop:
            return stop(wouldStopLabel, ink: palette.mark, detail: discard, palette: palette, width: width)
                + ["", next(guardClaude, "stop it for real", palette: palette, width: width)]
        case .letThrough:
            return wrap("rv let \(command) through. It did not run here.", indent: "  ", width: width)
                + ["", next(doctor, "find out why", palette: palette, width: width)]
        }
    }

    /// `  ✕ Stopped   git reset --hard`, then the detail hung under the
    /// command. The command starts at column 14, as in the frame, or two
    /// spaces after a longer label.
    private static func stop(
        _ label: String, ink: String, detail: String, palette: Palette, width: Int
    ) -> [String] {
        let gap = String(repeating: " ", count: max(2, 12 - label.count))
        let hang = String(repeating: " ", count: 2 + label.count + gap.count)
        return ["  \(paint(label, ink, palette))\(gap)\(command)"]
            + wrap(detail, indent: hang, width: width).map { paint($0, palette.muted, palette, keeping: hang) }
    }

    /// `  → <command>    <words>`; the words go when the line would not fit,
    /// so the command is never broken.
    private static func next(_ command: String, _ words: String, palette: Palette, width: Int) -> String {
        let head = "  \(paint("\(Glyph.next.rawValue) \(command)", palette.heading, palette))"
        let full = 2 + 2 + command.count + 4 + words.count
        return full <= width ? "\(head)    \(words)" : head
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

    /// Greedy word wrap, each line prefixed by `indent`; a word longer than
    /// the room left gets a line of its own.
    static func wrap(_ text: String, indent: String, width: Int) -> [String] {
        let room = max(width - indent.count, 1)
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= room {
                line += " " + word
            } else {
                lines.append(indent + line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(indent + line) }
        return lines
    }

    private static func paint(_ text: String, _ ink: String, _ palette: Palette, keeping indent: String = "") -> String {
        guard palette.colorsEnabled else { return text }
        return indent + ink + text.dropFirst(indent.count) + palette.reset
    }
}

// MARK: - Demo (shell)

/// Builds the throwaway repo, asks rv about the fake agent's command,
/// checks the work is intact, removes the repo, then prints the screen.
enum TryDemo {
    struct Options: Sendable {
        /// Parent of the one directory `rv try` creates (and removes).
        var tempRoot: URL
        /// The caller's environment; only `PATH` reaches git.
        var environment: [String: String]
        /// Claude Code's effective guard mode (`claudeGuardMode`).
        var guardMode: GuardMode
        var palette: Palette
        var columns: Int
        /// Short pauses between beats on a terminal; never when piped.
        var paced: Bool
        /// Catch SIGINT, SIGTERM and SIGHUP while the temp dir exists, so
        /// it is removed before rv exits. Process-wide; the command only.
        var catchesSignals = false
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

    /// What the run found, measured before the sandbox is removed.
    struct Rehearsal: Sendable {
        var work: TryUnsavedWork
        var deniedByRV: Bool
        var intact: Bool
    }

    struct Interrupted: Error {}

    /// `$TMPDIR` from the caller's environment, else the system temp dir.
    static func tempRoot(environment: [String: String]) -> URL {
        if let tmp = environment["TMPDIR"], tmp.hasPrefix("/") {
            return URL(fileURLWithPath: tmp, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// Claude Code's effective guard mode, as `rv host list` resolves it:
    /// `RV_GUARD_MODE=enforce` > `guard.hosts.claude` > `guard.mode` >
    /// enforce, and an organization gate pins enforce. Reads only.
    static func claudeGuardMode(home: HomeDirectory?, environment: [String: String]) -> GuardMode {
        if ManagedGate.pinsEnforce(home: home) { return .enforce }
        return GuardModeResolution.resolve(GuardConfig.read(home: home), host: .claude, environment: environment)
    }

    /// Exit code: 0 when a real agent's reset would be stopped and the
    /// work stayed intact; 128 + the signal when interrupted; else 1.
    static func run(_ options: Options) async -> Int32 {
        let signals = options.catchesSignals ? SignalCapture() : nil
        let catches = options.catchesSignals
        let rehearsal = await rehearse(options, interrupted: { catches && SignalCapture.anyCaught })
        signals?.release()
        if let caught = signals?.caught { return 128 + caught }

        let found: Rehearsal
        switch rehearsal {
        case .success(let value):
            found = value
        case .failure(let error):
            options.writeError("rv try: could not build the throwaway repo: \(error)\n")
            return 1
        }
        guard found.intact else {
            options.writeError("rv try: the throwaway repo changed while rv looked at it\n")
            return 1
        }

        let outcome: TryOutcome = !found.deniedByRV ? .letThrough
            : options.guardMode == .enforce ? .stopped : .wouldStop
        let screen = TryScreen.lines(outcome, work: found.work, palette: options.palette, columns: options.columns)
        options.write(PrettyWriter.join(screen.intro))
        await pause(options, milliseconds: 600)
        options.write(PrettyWriter.join(screen.stop))
        return outcome == .stopped ? 0 : 1
    }

    /// Everything that touches the disk, start to finish, with the sandbox
    /// removed at the end by this function alone.
    private static func rehearse(
        _ options: Options, interrupted: @escaping @Sendable () -> Bool
    ) async -> Result<Rehearsal, any Error> {
        let sandbox: Sandbox
        do {
            sandbox = try await BlockingIO.run { try makeSandbox(in: options.tempRoot) }
        } catch {
            return .failure(error)
        }
        let result: Result<Rehearsal, any Error>
        do {
            let git = try TryGit(sandbox: sandbox, environment: options.environment)
            let (written, work) = try await BlockingIO.run {
                let written = try TryRepo.build(at: sandbox.repo, git: git, interrupted: interrupted)
                return (written, try TryRepo.unsavedWork(git: git))
            }
            if interrupted() { throw Interrupted() }
            let denied = await deniedByRV(in: sandbox)
            if interrupted() { throw Interrupted() }
            let intact = try await BlockingIO.run { try TryRepo.isIntact(git: git, written: written, work: work) }
            result = .success(Rehearsal(work: work, deniedByRV: denied, intact: intact))
        } catch {
            result = .failure(error)
        }
        _ = try? await BlockingIO.run { try FileManager.default.removeItem(at: sandbox.root) }
        return result
    }

    /// rv's in-process evaluate, as Claude Code's hook would ask it, with
    /// day-one policy (no home) and an allow-once store inside the sandbox:
    /// true when the hook would send a deny. A peek: it records nothing and
    /// mints no code. Under observe it is the verdict guard mode reaches.
    static func deniedByRV(in sandbox: Sandbox) async -> Bool {
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
        return hostDenyText(from: verdict.shown, command: command) != nil
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
    /// Blocking: call it off the cooperative pool.
    static func build(
        at repo: URL, git: TryGit, interrupted: () -> Bool = { false }
    ) throws -> [String: Data] {
        try git.run(["init", "-q"])
        for (path, _) in files {
            try write(Data(committed(path).utf8), to: repo.appendingPathComponent(path))
        }
        if interrupted() { throw TryDemo.Interrupted() }
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

    /// What `git reset --hard` would discard, as git counts it. Blocking.
    static func unsavedWork(git: TryGit) throws -> TryUnsavedWork {
        let rows = try git.output(["diff", "--numstat", "HEAD"])
            .split(separator: "\n")
            .map { $0.split(separator: "\t", maxSplits: 2) }
            .filter { $0.count == 3 }
        let lines = rows.reduce(0) { $0 + (Int($1[0]) ?? 0) + (Int($1[1]) ?? 0) }
        return TryUnsavedWork(files: rows.count, lines: lines)
    }

    /// Every file still holds exactly what was written, and git still sees
    /// the same unsaved work. Blocking.
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

    /// Blocking: call it off the cooperative pool.
    func run(_ arguments: [String]) throws {
        _ = try output(arguments)
    }

    /// Runs git and returns its stdout. Stdout and stderr drain at the same
    /// time, so neither pipe can fill and stall git. Blocking.
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
        let errors = Mutex(Data())
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errors.withLock { $0 = data }
            drained.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = errors.withLock { String(decoding: $0, as: UTF8.self) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Holds SIGINT, SIGTERM and SIGHUP while `rv try` has a temp dir, and only
/// notes which arrived: `TryDemo.run` removes the dir itself, then exits
/// 128 + the signal. One capture at a time per process (signals are).
private struct SignalCapture {
    private static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    private static let received = Atomic<Int32>(0)
    private let sources: [any DispatchSourceSignal]

    init() {
        Self.received.store(0, ordering: .sequentiallyConsistent)
        sources = Self.signals.map { number in
            _ = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                _ = Self.received.compareExchange(expected: 0, desired: number, ordering: .sequentiallyConsistent)
            }
            source.resume()
            return source
        }
    }

    /// A signal arrived since the last capture began.
    static var anyCaught: Bool { received.load(ordering: .sequentiallyConsistent) != 0 }

    /// The first signal that arrived, if any.
    var caught: Int32? {
        let number = Self.received.load(ordering: .sequentiallyConsistent)
        return number == 0 ? nil : number
    }

    /// Back to the default actions: nothing is left to clean up.
    func release() {
        for source in sources { source.cancel() }
        for number in Self.signals { _ = signal(number, SIG_DFL) }
    }
}
