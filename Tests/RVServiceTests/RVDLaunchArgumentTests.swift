import Testing
@testable import RVService

struct RVDLaunchArgumentTests {
    @Test func helpPrintsUsageInsteadOfServing() throws {
        for flag in ["-h", "--help"] {
            let configuration = try RVDLaunch.parse(arguments: ["rvd", flag])
            #expect(configuration.printHelp)
            #expect(configuration.printVersion == false)
        }
        #expect(RVDLaunch.usage.contains("rv service status"))
        #expect(RVDLaunch.usage.contains("--idle-exit-seconds"))
    }

    @Test func unknownArgumentsAreRefusedSoRvdNeverStartsByAccident() {
        #expect(throws: RVDLaunchError.unknownArgument("--frobnicate")) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "--frobnicate"])
        }
        #expect(throws: RVDLaunchError.unknownArgument("serve")) {
            _ = try RVDLaunch.parse(arguments: ["rvd", "serve"])
        }
    }

    @Test func anUnknownArgumentIsEscapedBeforeItIsPrinted() {
        let message = RVDLaunch.unknownArgumentMessage("--x\u{1B}[2J")
        #expect(message.contains("\u{1B}") == false)
        #expect(message.hasPrefix("rvd: unknown argument '--x"))
        #expect(message.hasSuffix("manage rvd with rv service.\n"))
    }

    @Test func theArgumentsLaunchdAndSetupPassStillParse() throws {
        #expect(try RVDLaunch.parse(arguments: ["rvd"]).printHelp == false)
        #expect(try RVDLaunch.parse(arguments: ["rvd", "--version"]).printVersion)
        #expect(try RVDLaunch.parse(arguments: ["rvd", "--idle-exit-seconds=60"]).idleExitSeconds == 60)
    }
}
