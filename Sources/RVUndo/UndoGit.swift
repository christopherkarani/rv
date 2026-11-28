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
/// `core.fsmonitor`, commit signing, clean/smudge filters, and anything
/// that reaches the network: a partial clone's lazy fetch runs the
/// remote's transport (`ext::<command>`), with its `core.sshCommand`,
/// credential helpers and `remote-<x>` helpers. rvd runs these copies
/// outside any box the agent is in, so none of them may run (`.keeper`):
/// - lazy fetches are off (`GIT_NO_LAZY_FETCH`) and no transport is
///   allowed at all (`GIT_ALLOW_PROTOCOL=none`, which outranks every
///   `protocol.*.allow` in a repo's config), so no remote, ssh command,
///   credential or remote helper is ever reached;
/// - hooks, fsmonitor, signing, reflogs and auto maintenance are switched
///   off on the command line, which outranks every config file;
/// - global and system config are not read;
/// - git is pinned to `<root>/.git` (`GIT_DIR`, `GIT_WORK_TREE`,
///   `GIT_CEILING_DIRECTORIES`): it never walks up to a parent repository;
/// - git writes nothing in the repository: new objects go to the copy's
///   own folder in rv's store (`GIT_OBJECT_DIRECTORY`), the repository's
///   objects are only read (`GIT_ALTERNATE_OBJECT_DIRECTORIES`), the
///   index git works on is a copy, and no ref is made;
/// - rvd never runs a git command that reads working-tree files (that is
///   where filters run): `UndoGitCopy` reads the files itself and hands
///   git their bytes with `hash-object --no-filters`;
/// - `UndoRepository.check` refuses a repository set up to redirect any of
///   this (a `.git` that is not a plain folder, linked object or ref
///   folders, alternates, partial clones, unknown extensions).
/// Every run has a deadline: none starts past it, and one still running
/// near it is killed, so the wait ends by the deadline.
///
/// `.person` is for `rv undo` restoring at the person's own terminal: the
/// person's normal git (their global config, so LFS and smudge filters
/// work), with hooks and fsmonitor still off.
public struct UndoGit: Sendable {
    public enum Mode: Sendable {
        case keeper
        case person
    }

    let executable: URL
    let repository: String
    var deadline: ContinuousClock.Instant
    var mode: Mode = .keeper
    /// Where new objects go (a folder in rv's store), with the
    /// repository's own objects read as an alternate. Nil: the
    /// repository's objects (only for runs that write none).
    var objectDirectory: String?
    /// Most output read from one run. Past it the run fails.
    static let maxOutput = 4 * 1024 * 1024
    /// A run still going this close to the deadline is killed, so reaping
    /// it ends by the deadline.
    static let killMargin: Duration = .milliseconds(150)

    init(
        executable: URL, repository: String, deadline: ContinuousClock.Instant, mode: Mode = .keeper,
        objectDirectory: String? = nil
    ) {
        self.executable = executable
        self.repository = repository
        self.deadline = deadline
        self.mode = mode
        self.objectDirectory = objectDirectory
    }

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

    /// Flags on every keeper run: no hooks, fsmonitor, pager, prompts,
    /// transports, signing, reflogs or maintenance, and nothing to call
    /// for ssh or credentials should anything still reach for them.
    static let hardening = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "core.pager=cat",
        "-c", "core.logAllRefUpdates=false",
        "-c", "core.sshCommand=/bin/false",
        "-c", "credential.helper=",
        "-c", "protocol.allow=never",
        "-c", "fetch.recurseSubmodules=false",
        "-c", "commit.gpgSign=false",
        "-c", "gc.auto=0",
        "-c", "maintenance.auto=false",
        "-c", "core.sharedRepository=false",
    ]

    /// Flags on a person's restore: hooks and fsmonitor off, the rest is
    /// their own git.
    static let personHardening = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
    ]

    var arguments: [String] { mode == .keeper ? Self.hardening : Self.personHardening }

    /// Pins git to `<root>/.git`, never a parent repository's.
    static func pinned(_ env: inout [String: String], root: String) {
        env["GIT_DIR"] = root + "/.git"
        env["GIT_WORK_TREE"] = root
        env["GIT_CEILING_DIRECTORIES"] = (root as NSString).deletingLastPathComponent
    }

    static func environment(
        mode: Mode = .keeper, root: String? = nil, base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String]
        switch mode {
        case .keeper:
            env = [
                "PATH": "/usr/bin:/bin",
                "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_PAGER": "cat",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_NO_LAZY_FETCH": "1",
                "GIT_ALLOW_PROTOCOL": "none",
                "GIT_PROTOCOL_FROM_USER": "0",
                "GIT_SSH_COMMAND": "/bin/false",
                "GIT_ASKPASS": "/bin/false",
                "SSH_ASKPASS": "/bin/false",
                // rv's kept commits need a name, never yours.
                "GIT_AUTHOR_NAME": "rv", "GIT_AUTHOR_EMAIL": "rv@localhost",
                "GIT_COMMITTER_NAME": "rv", "GIT_COMMITTER_EMAIL": "rv@localhost",
            ]
            if let home = base["HOME"] { env["HOME"] = home }
        case .person:
            // The person's own environment, minus anything that would
            // point git somewhere other than this repository.
            env = base.filter { key, _ in
                ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CEILING_DIRECTORIES", "GIT_NAMESPACE",
                 "GIT_COMMON_DIR"].contains(key) == false
            }
        }
        if let root { pinned(&env, root: root) }
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
        // Past the deadline nothing starts.
        guard ContinuousClock.now + Self.killMargin < deadline else { throw .outOfTime }
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
        process.arguments = self.arguments + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repository, isDirectory: true)
        var environment = Self.environment(mode: mode, root: repository)
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile }
        if let objectDirectory {
            environment["GIT_OBJECT_DIRECTORY"] = objectDirectory
            environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = Self.quotedAlternate(repository + "/.git/objects")
        }
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
        // Killed at the margin before the deadline, so the wait for it to
        // go ends by the deadline.
        let left = deadline - Self.killMargin - ContinuousClock.now
        let seconds = max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        if done.wait(timeout: .now() + seconds) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 0.1)
            throw .outOfTime
        }
        try? out.close()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outPath),
            let size = attributes[.size] as? NSNumber, size.intValue <= maxOutput,
            let data = FileManager.default.contents(atPath: outPath)
        else { throw .gitFailed("too much output") }
        return Output(status: process.terminationStatus, stdout: data)
    }

    /// One entry of `GIT_ALTERNATE_OBJECT_DIRECTORIES`, C-quoted the way
    /// git reads it, so a `:` (the list separator) or any other byte in
    /// the path is taken literally.
    static func quotedAlternate(_ path: String) -> String {
        var quoted = "\""
        for byte in path.utf8 {
            switch byte {
            case UInt8(ascii: "\\"): quoted += "\\\\"
            case UInt8(ascii: "\""): quoted += "\\\""
            case 0..<0x20, 0x7F...0xFF: quoted += "\\" + String(byte, radix: 8).leftPadded(to: 3)
            default: quoted.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return quoted + "\""
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

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
