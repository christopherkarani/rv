import Foundation

/// What an interpreter really runs, as its own `sys` reports it with
/// symlinks resolved. macOS's `/usr/bin/python3` is an xcrun launcher:
/// root-owned itself, it execs the Python of the active developer
/// directory, which may be a user-owned `Xcode.app`. Only the resolved
/// paths say who can replace the code a hook runs.
struct InterpreterIdentity: Equatable, Sendable {
    /// `realpath(sys.executable)`.
    let executable: String
    /// `realpath(sys.prefix)`: where the standard library lives.
    let prefix: String
    /// `realpath(os.__file__)`: one standard library module the hook loads.
    let stdlib: String

    /// Run with the hook's flags: prints the three paths, one per line.
    static let probeScript = "import os,sys\n"
        + "e=sys.executable\n"
        + "if not e: sys.exit(1)\n"
        + "r=os.path.realpath\n"
        + "print(r(e));print(r(sys.prefix));print(r(os.__file__))\n"

    /// Exactly three absolute lines, or nil.
    static func parse(_ output: String) -> InterpreterIdentity? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.count == 3, lines.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return InterpreterIdentity(executable: lines[0], prefix: lines[1], stdlib: lines[2])
    }
}

/// The system interpreters setup tries before walking PATH, in order.
struct SystemInterpreterSearch {
    /// Real interpreters, probed as they are.
    var direct: [String]
    /// Launchers (macOS's xcrun `/usr/bin/python3`), probed only when
    /// `launchersUsable()`: run without the developer tools, the launcher
    /// pops the "install the command line developer tools" dialog.
    var launchers: [String]
    var launchersUsable: () -> Bool

    /// The Command Line Tools' root-owned Python before the launcher;
    /// Linux's `/usr/bin` holds the real interpreter.
    static func live(_ name: String) -> SystemInterpreterSearch {
#if os(macOS)
        SystemInterpreterSearch(
            direct: [AdapterRuntime.commandLineToolsDirectory + "/" + name],
            launchers: ["/usr/bin/" + name],
            launchersUsable: AdapterRuntime.developerDirectorySelected
        )
#else
        SystemInterpreterSearch(direct: ["/usr/bin/" + name], launchers: [], launchersUsable: { false })
#endif
    }

    func candidates() -> [String] {
        guard launchers.isEmpty == false, launchersUsable() else { return direct }
        return direct + launchers
    }
}

extension AdapterRuntime {
    static let commandLineToolsDirectory = "/Library/Developer/CommandLineTools/usr/bin"

    /// The interpreter setup bakes: the first system candidate whose real
    /// interpreter is protected (`isProtectedSystemInterpreter`) and runs,
    /// else the first runnable `name` on PATH. A conda, pyenv or Homebrew
    /// `python3` is one an agent could swap to skip the guard (doctor warns
    /// about that fallback). The baked path is the real interpreter, never
    /// a launcher, so no hook pays for or depends on an xcrun hop. An
    /// absolute `name` is probed as is.
    static func chooseRunnable(
        _ name: String,
        pathEntries: [String],
        search: SystemInterpreterSearch? = nil,
        identify: (String) -> InterpreterIdentity? = identify,
        isProtected: (InterpreterIdentity) -> Bool = isProtectedSystemInterpreter
    ) -> String? {
        if name.hasPrefix("/") == false {
            for candidate in (search ?? .live(name)).candidates()
            where FileManager.default.isExecutableFile(atPath: candidate) {
                guard let identity = identify(candidate), isProtected(identity) else { continue }
                let baked = bakedPath(candidate, identity: identity)
                if userCanReplace(baked) == false, let runnable = resolveRunnable(baked, pathEntries: []) {
                    return runnable
                }
            }
        }
        return resolveRunnable(name, pathEntries: pathEntries)
    }

    /// `candidate` itself when it is a symlink chain to the real
    /// interpreter (it survives a version upgrade behind it); else the real
    /// interpreter, so a launcher is never baked.
    static func bakedPath(_ candidate: String, identity: InterpreterIdentity) -> String {
        realPath(candidate) == identity.executable ? candidate : identity.executable
    }

    /// The real interpreter, `sys.prefix` and the standard library file are
    /// each `isRootProtected`: root owns every directory, link and file on
    /// their paths and this user can write none of them.
    static func isProtectedSystemInterpreter(_ identity: InterpreterIdentity) -> Bool {
        canReplace(identity) == false
    }

    /// Any of the interpreter, its prefix or the standard library it loads
    /// is not `isRootProtected`.
    static func canReplace(_ identity: InterpreterIdentity) -> Bool {
        [identity.executable, identity.prefix, identity.stdlib].contains(where: userCanReplace)
    }

    /// Doctor's check of a baked interpreter: the path itself, then what it
    /// really runs. One that will not say what it runs counts as
    /// replaceable.
    static func isReplaceableInterpreter(
        _ path: String,
        identify: (String) -> InterpreterIdentity? = identify
    ) -> Bool {
        if userCanReplace(path) { return true }
        guard let identity = identify(path) else { return true }
        return canReplace(identity)
    }

    /// Runs `executable` with the hook's flags and asks it what it runs.
    static func identify(_ executable: String) -> InterpreterIdentity? {
        runWithHookFlags(executable, code: InterpreterIdentity.probeScript).flatMap(InterpreterIdentity.parse)
    }

    /// `xcode-select -p` exits 0: a developer directory is selected, so the
    /// xcrun launcher runs a Python instead of prompting an install.
    static func developerDirectorySelected() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        return wait(process, output: nil)
    }

    /// Symlink hops `isRootProtected` follows before giving up.
    static let maxSymlinkHops = 32

    /// Anything other than `isRootProtected`: this user could replace what
    /// `path` names, or the path does not resolve.
    static func userCanReplace(_ path: String) -> Bool {
        isRootProtected(path) == false
    }

    /// Every directory from `/` down, every symlink hop and the file it
    /// ends at is owned by root (uid 0), and no directory or file on the
    /// way is writable by this user. Owning a read-only directory is not
    /// enough: an owner can `chmod` it back. False for a relative path,
    /// one that does not resolve, or more than `maxSymlinkHops` links.
    static func isRootProtected(_ path: String) -> Bool {
        isRootProtected(path, hops: 0)
    }

    private static func isRootProtected(_ path: String, hops: Int) -> Bool {
        guard path.hasPrefix("/"), hops <= maxSymlinkHops, rootOwnedUnwritable("/") else { return false }
        var current = "/"
        let names = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for (index, name) in names.enumerated() {
            if name == "." { continue }
            if name == ".." {
                current = (current as NSString).deletingLastPathComponent
                continue
            }
            let entry = (current as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(entry, &info) == 0, info.st_uid == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                // The link is root's and sits in a directory checked above;
                // continue at its target, checked from `/` again.
                guard let target = readLink(entry) else { return false }
                let base = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                let rest = names[(index + 1)...].joined(separator: "/")
                return isRootProtected(rest.isEmpty ? base : base + "/" + rest, hops: hops + 1)
            }
            guard access(entry, W_OK) != 0 else { return false }
            current = entry
        }
        return true
    }

    private static func rootOwnedUnwritable(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == 0 && access(path, W_OK) != 0
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, Int(PATH_MAX))
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `realpath(3)`, or nil when `path` does not resolve.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Stdout of `<executable> -I -S -c <code>` when it exits 0 within
    /// `probeTimeout`.
    static func runWithHookFlags(_ executable: String, code: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // The hook command's own flags: an interpreter that rejects them
        // (Python 2 has no `-I`) would fail every hook.
        process.arguments = AdapterCommand.isolationFlags.split(separator: " ").map(String.init) + ["-c", code]
        let output = Pipe()
        guard wait(process, output: output) else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Runs `process` with no input, stderr discarded and stdout to
    /// `output` (or discarded); true when it exits 0 within `probeTimeout`.
    private static func wait(_ process: Process, output: Pipe?) -> Bool {
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard exited.wait(timeout: .now() + probeTimeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
