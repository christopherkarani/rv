import Foundation
import RVDomain

/// The interpreter a host's hook command starts. Claude, Codex, Cursor and
/// Antigravity run `<python3> -I -S …/rv-guard.py`, with the `python3`
/// setup found on PATH baked in (`AdapterCommand`); when it is missing the
/// shell exits 127 and those hosts treat it as a non-blocking hook error,
/// so the guard silently fails open. Other adapters load inside the host's
/// own runtime (pi, OpenCode, OpenClaw, Hermes) or exec `rv` directly
/// (Grok, Muse) and start no interpreter of their own.
enum AdapterRuntime {
    static let python3 = "python3"
    /// Ceiling for one `python3 -c` probe.
    static let probeTimeout: TimeInterval = 5

    static func interpreter(for host: HookHost) -> String? {
        switch host {
        case .claude, .codex, .cursor, .antigravity:
            python3
        case .grok, .pi, .opencode, .openclaw, .hermes, .muse:
            nil
        }
    }

    /// One line naming the hosts left unwired (setup) and why.
    static func setupRefusal(hosts: [HookHost], interpreter: String) -> String {
        let names = hosts.map(\.rawValue).joined(separator: ", ")
        return "rv setup: not wiring \(names): \(interpreter) is not runnable, so the hook would fail open "
            + "(the host treats a missing interpreter as a non-blocking error)\n"
            + "fix: \(installHint(interpreter)), then rerun rv setup\n"
    }

    static func installHint(_ interpreter: String) -> String {
        #if os(macOS)
        "install \(interpreter) (xcode-select --install, or brew install python)"
        #else
        "install \(interpreter) with your package manager (e.g. apt install python3)"
        #endif
    }

    /// Hosts whose hook is in place (wired or needing repair): the ones a
    /// missing interpreter leaves failing open.
    static func hooked(_ hosts: HostAdapterInstallationSnapshot) -> [HookHost] {
        HookHost.setupSlotOrder.filter { host in
            switch hosts.installation(for: host) {
            case .wired, .broken: true
            case .missing, .absentFile, .occupied: false
            }
        }
    }

    /// The interpreters this host's rv hook commands start, read from its
    /// hook file: each baked path, or `python3` for an earlier rv's PATH
    /// command. Empty when the file or a command does not parse.
    static func bakedInterpreters(host: HookHost, paths: OwnedPaths, fileManager: FileManager) -> [String] {
        let source: (file: String, descriptor: HostWiringDescriptor)
        switch host {
        case .claude: source = (paths.claudeSettings, ClaudeSettingsMerge.wiringDescriptor)
        case .antigravity: source = (paths.antigravityHooksJSON, AntigravityHooksMerge.wiringDescriptor)
        case .codex: source = (paths.codexHooksJSON, CodexHooksMerge.wiringDescriptor)
        case .cursor: source = (paths.cursorHooksJSON, CursorHooksMerge.wiringDescriptor)
        case .grok, .pi, .opencode, .openclaw, .hermes, .muse: return []
        }
        guard let data = fileManager.contents(atPath: source.file),
              let root = try? HostHooksMergeEngine.parseRoot(data)
        else { return [] }
        var interpreters: [String] = []
        for located in HostHooksMergeEngine.locateFingerprintedHooks(in: root, descriptor: source.descriptor) {
            guard let interpreter = located.hook["command"]?.string.flatMap(interpreter(inHookCommand:)) else {
                return []
            }
            if interpreters.contains(interpreter) == false { interpreters.append(interpreter) }
        }
        return interpreters
    }

    /// `[RV_BINARY=<rv> ]<interpreter> …`: the interpreter word, absolute
    /// (current) or `python3` (earlier rv); nil otherwise.
    private static func interpreter(inHookCommand command: String) -> String? {
        var tail = Substring(command)
        let envPrefix = "RV_BINARY="
        if tail.hasPrefix(envPrefix) {
            guard let rv = ShellWord.leadingWord(tail.dropFirst(envPrefix.count)), rv.rest.hasPrefix(" ") else {
                return nil
            }
            tail = rv.rest.dropFirst()
        }
        guard let parsed = AdapterCommand.parse(tail) else { return nil }
        return parsed.isolated ? (parsed.interpreter.hasPrefix("/") ? parsed.interpreter : nil) : parsed.interpreter
    }

    /// Live check: the first `name` on `pathEntries` runs `-c pass` and
    /// exits 0 within `probeTimeout`. macOS's `/usr/bin/python3` is a stub
    /// that exists without the developer tools, so presence alone is not
    /// proof. An absolute `name` is probed as is.
    static func liveRunnable(_ name: String, pathEntries: [String]) -> Bool {
        resolveRunnable(name, pathEntries: pathEntries) != nil
    }

    /// The absolute path `liveRunnable` proved runs, as found on
    /// `pathEntries` (symlinks kept, so an upgrade behind them still works);
    /// nil when it does not run or the PATH entry is relative.
    static func resolveRunnable(_ name: String, pathEntries: [String]) -> String? {
        let fileManager = FileManager.default
        let candidates = name.hasPrefix("/")
            ? [name]
            : pathEntries.filter { $0.hasPrefix("/") }.map { ($0 as NSString).appendingPathComponent(name) }
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }),
              probe(executable)
        else { return nil }
        return executable
    }

    /// This user may write `path`, the file it resolves to, or a directory
    /// above either, so could replace what it runs.
    static func userCanReplace(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for start in [path, resolved] {
            var current = start
            while current.isEmpty == false {
                if access(current, W_OK) == 0 { return true }
                let parent = (current as NSString).deletingLastPathComponent
                if parent == current { break }
                current = parent
            }
        }
        return false
    }

    private static func probe(_ executable: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // The hook command's own flags: an interpreter that rejects them
        // (Python 2 has no `-I`) would fail every hook.
        process.arguments = AdapterCommand.isolationFlags.split(separator: " ").map(String.init) + ["-c", "pass"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
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

extension HostAdapterInstallation {
    /// Setup would write this host's hook without `--force`.
    var wouldWire: Bool {
        switch self {
        case .absentFile, .broken, .wired: true
        case .missing, .occupied: false
        }
    }

    /// Setup writes this host's hook: `wouldWire`, or occupied under `--force`.
    func wouldWrite(force: Bool) -> Bool {
        if case .occupied = self { return force }
        return wouldWire
    }
}
