#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVPolicy

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

        init(
            home: HomeDirectory? = nil,
            environment: [String: String] = [:],
            stdinIsTTY: Bool? = nil,
            stdoutIsTTY: Bool? = nil,
            stdoutFileDescriptor: Int32? = nil,
            workspacePath: String? = nil,
            stdinText: String? = nil,
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
