#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIPC
import RVPolicy
import RVTheme
import Synchronization

/// In-memory stdout/stderr sink. Installed on `CLIProcess.Context` so command
/// output lands here instead of the process file descriptors.
final class CLIOutputCapture: Sendable {
    private let state = Mutex<(stdout: String, stderr: String)>(("", ""))

    init() {}

    var stdout: String { state.withLock { $0.stdout } }
    var stderr: String { state.withLock { $0.stderr } }

    func appendStdout(_ text: String) {
        state.withLock { $0.stdout += text }
    }

    func appendStderr(_ text: String) {
        state.withLock { $0.stderr += text }
    }
}

/// In-process overrides for operator HOME / TTY / env. Production reads the
/// process; tests install a `Context` so `run()` never touches live `$HOME`.
enum CLIProcess: Sendable {
    struct Context: Sendable {
        var home: HomeDirectory?
        var environment: [String: String]
        var stdinIsTTY: Bool?
        var stdoutIsTTY: Bool?
        var stdoutFileDescriptor: Int32?
        var workspacePath: String?
        var stdinText: String?
        /// Scripted device-owner outcome for `rv allow-once`. Nil fails
        /// closed (tests never reach live LocalAuthentication).
        var ownerAuthOutcome: UIAuthenticationOutcome?
        /// Stand-in for `rv policy draft`'s English compiler. Nil uses the
        /// live chain, which reaches Apple Intelligence where it is enabled.
        var englishCompiler: (any EnglishCompiler)?
        /// When set, `CommandContext.writeStdout/writeStderr` append here
        /// instead of writing to the process file descriptors.
        var output: CLIOutputCapture?

        init(
            home: HomeDirectory? = nil,
            environment: [String: String] = [:],
            stdinIsTTY: Bool? = nil,
            stdoutIsTTY: Bool? = nil,
            stdoutFileDescriptor: Int32? = nil,
            workspacePath: String? = nil,
            stdinText: String? = nil,
            ownerAuthOutcome: UIAuthenticationOutcome? = nil,
            englishCompiler: (any EnglishCompiler)? = nil,
            output: CLIOutputCapture? = nil,
            includeProcessEnvironment: Bool = false
        ) {
            self.home = home
            var merged = includeProcessEnvironment
                ? ProcessInfo.processInfo.environment
                : environment
            if includeProcessEnvironment {
                for (key, value) in environment {
                    merged[key] = value
                }
            }
            if let home {
                merged["HOME"] = home.rawValue
            }
            self.environment = merged
            self.stdinIsTTY = stdinIsTTY
            self.stdoutIsTTY = stdoutIsTTY
            self.stdoutFileDescriptor = stdoutFileDescriptor
            self.workspacePath = workspacePath
            self.stdinText = stdinText
            self.ownerAuthOutcome = ownerAuthOutcome
            self.englishCompiler = englishCompiler
            self.output = output
        }
    }

    @TaskLocal static var context: Context?

    static func home() -> HomeDirectory? {
        if let context {
            if let home = context.home { return home }
            return HomeDirectory(validating: environment()["HOME"] ?? "")
        }
        return HomeDirectory.process()
    }

    static func environment() -> [String: String] {
        context?.environment ?? ProcessInfo.processInfo.environment
    }

    static func stdinIsTTY() -> Bool {
        context?.stdinIsTTY ?? (isatty(STDIN_FILENO) != 0)
    }

    static func stdoutIsTTY() -> Bool {
        context?.stdoutIsTTY ?? (isatty(STDOUT_FILENO) != 0)
    }

    /// The terminal the background probe asks. Installed contexts get none,
    /// so tests never write a query to the operator's terminal.
    static func terminalQueryChannel() -> any TerminalQueryChannel {
        context == nil ? StandardTerminalChannel() : UnavailableTerminalChannel()
    }

    static func stdoutFileDescriptor() -> Int32 {
        context?.stdoutFileDescriptor ?? STDOUT_FILENO
    }

    static func workspacePath() -> String {
        context?.workspacePath ?? FileManager.default.currentDirectoryPath
    }

    static func standardInputText() -> String {
        if let context, let stdinText = context.stdinText {
            return stdinText
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
