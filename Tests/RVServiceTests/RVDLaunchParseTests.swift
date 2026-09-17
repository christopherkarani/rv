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
