import Foundation
import Testing
@testable import RVService

struct RVDLaunchParseTests {
    @Test func defaultArguments_keepIdleAndHideVersion() throws {
        let config = try RVDLaunch.parse(arguments: ["rvd"])
        #expect(config.idleExitSeconds == IdleWatchdog.defaultSeconds)
        #expect(config.printVersion == false)
        #expect(RVDLaunch.versionLine.isEmpty == false)
    }

    @Test func versionFlag_setsPrintVersion() throws {
        let config = try RVDLaunch.parse(arguments: ["rvd", "--version"])
        #expect(config.printVersion)
        #expect(config.idleExitSeconds == IdleWatchdog.defaultSeconds)
    }

    @Test func idleExitSeconds_spaceAndEqualsForms() throws {
        let spaced = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds", "12"])
        #expect(spaced.idleExitSeconds == 12)
        #expect(spaced.printVersion == false)
        let equals = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds=8", "--version"])
        #expect(equals.idleExitSeconds == 8)
        #expect(equals.printVersion)
    }

    @Test func idleExitSeconds_rejectsMissingZeroAndNonInteger() {
        #expect(throws: RVDLaunchError.invalidIdleExit) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds"])
        }
        #expect(throws: RVDLaunchError.invalidIdleExit) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds", "0"])
        }
        #expect(throws: RVDLaunchError.invalidIdleExit) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds", "-3"])
        }
        #expect(throws: RVDLaunchError.invalidIdleExit) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds=abc"])
        }
        #expect(throws: RVDLaunchError.invalidIdleExit) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds=0"])
        }
    }

    /// G3: rvd does not serve without a home, on Linux too, where the
    /// socket path never needed one.
    @Test func launchRequiresAnAbsoluteHome() throws {
        let refused: [[String: String]] = [
            [:], ["HOME": ""], ["HOME": "rel"], ["HOME": "~"], ["HOME": "~/x"], ["HOME": "/home/a\0b"],
        ]
        for environment in refused {
            #expect(RVDLaunch.validatedHome(environment: environment) == nil, "\(environment)")
            #expect(throws: RVDLaunchError.homeRequired, "\(environment)") {
                try RVDLaunch.requireHome(environment: environment)
            }
        }
        for home in ["/home/owner", "/home/x/"] {
            #expect(RVDLaunch.validatedHome(environment: ["HOME": home]) == home)
            try RVDLaunch.requireHome(environment: ["HOME": home])
        }
    }

    /// G3: both `RVDProcess.run` variants (XPC and Unix socket) check HOME
    /// before anything else. Only one of them compiles per platform, so the
    /// other is checked in the source.
    @Test func bothRunVariantsCheckHomeFirst() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RVService/RVDProcess.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = "public static func run(configuration: RVDConfiguration) throws {\n"
        let check = "        try RVDLaunch.requireHome(environment: ProcessInfo.processInfo.environment)\n"
        #expect(text.components(separatedBy: entry).count == 3, "expected two run variants")
        #expect(text.components(separatedBy: entry + check).count == 3, "each run must check HOME first")
    }

    /// Before rvd's first write (the log line `captureDiscardedStderr`
    /// writes): on Darwin its stdout and stderr are set not to raise
    /// SIGPIPE, per open file, so children keep the default disposition;
    /// on Linux SIGPIPE is ignored (systemd's unit already did; `rv service
    /// start` does not). The process tests prove the Darwin path. Nothing
    /// else in rvd's main changes the disposition.
    @Test func rvdStdioCannotRaiseSIGPIPEBeforeItsFirstWrite() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/rvd/main.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = "    static func main() {\n"
        let body = try #require(text.components(separatedBy: entry).dropFirst().first, "rvd main")
        let statements = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            line.isEmpty == false && line.hasPrefix("//") == false
        }
        #expect(Array(statements.prefix(7)) == [
            "#if canImport(Darwin)",
            "_ = fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1)",
            "_ = fcntl(STDERR_FILENO, F_SETNOSIGPIPE, 1)",
            "#else",
            "signal(SIGPIPE, SIG_IGN)",
            "#endif",
            "RVDLogFile.captureDiscardedStderr()",
        ])
        #expect(text.components(separatedBy: "SIGPIPE, SIG_IGN").count == 2, "ignored once, on Linux only")
    }

#if os(Linux)
    @Test func linuxSocketFlag_doesNotThrowAndCanCombineWithIdle() throws {
        let flagged = try RVDLaunch.parse(
            arguments: ["rvd", "--socket", "--idle-exit-seconds", "2", "--version"]
        )
        #expect(flagged.idleExitSeconds == 2)
        #expect(flagged.printVersion)
        let equals = try RVDLaunch.parse(arguments: ["rvd", "--socket=/ignored"])
        #expect(equals.idleExitSeconds == IdleWatchdog.defaultSeconds)
    }
#endif
}

#if os(Linux)
struct RVDProcessLinuxResidualTests {
    @Test func linuxProcessEntry_isCompiledAndXPCListenerIsAbsent() throws {
        let _: (RVDConfiguration) throws -> Void = RVDProcess.run
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RVService/RVDProcess.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("canImport(XPC)"))
        #expect(text.contains("UnixEvaluateListener"))
        #expect(text.contains("RunLoop.main.run()"))
        #expect(text.contains("Foundation.exit(0)"))
    }
}
#endif
