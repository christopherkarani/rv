#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Runs git for `rv undo`, hardened against the repository it runs in.
///
/// A repository's own config can make git run commands: hooks
/// (`reference-transaction` on `update-ref`, `post-checkout` on `switch`),
/// `core.fsmonitor`, commit signing, and clean/smudge filters. rvd runs
/// these copies outside any box the agent is in, so none of them may run:
/// - hooks, fsmonitor, signing and auto maintenance are switched off on
///   the command line, which outranks every config file;
/// - global and system config are not read;
/// - rvd never runs a git command that reads working-tree files (that is
///   where filters run): `UndoGitCopy` reads the files itself and hands
///   git their bytes with `hash-object --no-filters`.
/// Every run has a deadline; past it the process is killed.
public struct UndoGit: Sendable {
    let executable: URL
    let repository: String
    var deadline: ContinuousClock.Instant
    /// Most output read from one run. Past it the run fails.
    static let maxOutput = 4 * 1024 * 1024

    /// The git a person would get, never the macOS `/usr/bin/git` shim:
    /// without developer tools that shim opens an install dialog.
    public static func locate(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
        let candidates = [
            "/opt/homebrew/bin/git", "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        #else
        let candidates = ["/usr/bin/git", "/usr/local/bin/git", "/bin/git"]
        #endif
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Flags on every run: no hooks, no fsmonitor, no pager, no prompts.
    static let hardening = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.pager=cat",
        "-c", "protocol.allow=never",
        "-c", "commit.gpgSign=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
    ]

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_OPTIONAL_LOCKS": "0",
            // rv's kept commits need a name, never yours.
            "GIT_AUTHOR_NAME": "rv", "GIT_AUTHOR_EMAIL": "rv@localhost",
            "GIT_COMMITTER_NAME": "rv", "GIT_COMMITTER_EMAIL": "rv@localhost",
        ]
        if let home = base["HOME"] { env["HOME"] = home }
        return env
    }

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    /// Runs `git <hardening> <arguments>` in the repository. Output goes
    /// to an owner-only temp file, read once git exits, so a chatty git
    /// never blocks on a full pipe.
    /// `input`, when given, is git's stdin (through a temp file too).
    /// `indexFile` points git at an index other than the repository's.
    func run(
        _ arguments: [String], input: Data? = nil, indexFile: String? = nil, maxOutput: Int = UndoGit.maxOutput
    ) throws(UndoSkip) -> Output {
        let outPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-undo-git-\(UUID().uuidString)").path
        let fd = open(outPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw .io(outPath, errno: errno) }
        defer { unlink(outPath) }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var stdin = FileHandle.nullDevice
        let inPath = outPath + ".in"
        if let input {
            let inFD = open(inPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard inFD >= 0 else { throw .io(inPath, errno: errno) }
            let handle = FileHandle(fileDescriptor: inFD, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: input)
                try handle.seek(toOffset: 0)
            } catch {
                unlink(inPath)
                throw .io(inPath, errno: EIO)
            }
            stdin = handle
        }
        defer { if input != nil { unlink(inPath) } }
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.hardening + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repository, isDirectory: true)
        var environment = Self.environment()
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile }
        process.environment = environment
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            throw .gitUnavailable
        }
        let left = deadline - ContinuousClock.now
        let seconds = max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 0.2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + 1)
            throw .outOfTime
        }
        try? out.close()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outPath),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxOutput,
            let data = FileManager.default.contents(atPath: outPath)
        else { throw .gitFailed("too much output") }
        return Output(status: process.terminationStatus, stdout: data)
    }

    /// `run`, requiring exit 0, trimmed text out.
    func text(_ arguments: [String], input: Data? = nil, indexFile: String? = nil) throws(UndoSkip) -> String {
        let output = try run(arguments, input: input, indexFile: indexFile)
        guard output.status == 0 else { throw .gitFailed(arguments.first ?? "git") }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for a full commit id: 40 (SHA-1) or 64 (SHA-256) lowercase hex.
    public static func isObjectID(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64)
            && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
