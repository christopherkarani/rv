import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
@testable import RVCLI

struct PacksInfoTests {
    @Test func unknownPackNamesItOnStderr() async throws {
        let home = try isolatedHome()
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, output: out) {
            var command = try Packs.Info.parse(["nope"])
            await #expect(throws: ExitCode(1)) {
                try await command.run()
            }
        }
        #expect(out.stderr == "unknown pack id: nope (rv packs lists every pack)\n")
        #expect(out.stdout.isEmpty)
    }
}

/// Every owner-check refusal exits EX_NOPERM with one stderr line and no
/// usage banner.
struct OwnerRefusalExitTests {
    @Test func packsEnableAndDisableRefuseWithNoPerm() async throws {
        let home = try isolatedHome()
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, output: out) {
            var enable = try Packs.Enable.parse(["core.git"])
            await #expect(throws: ExitCode(EX_NOPERM)) { try await enable.run() }
            var disable = try Packs.Disable.parse(["core.git"])
            await #expect(throws: ExitCode(EX_NOPERM)) { try await disable.run() }
        }
        #expect(out.stderr == "rv: enable packs core.git needs owner authentication, which was not given\n"
            + "rv: disable packs core.git needs owner authentication, which was not given\n")
        #expect(out.stderr.contains("Usage") == false)
    }

    @Test func safetyRefusesWithNoPerm() async throws {
        let home = try isolatedHome()
        let out = CLIOutputCapture()
        try await withCLIProcess(home: home, output: out) {
            var command = try Safety.parse(["strict"])
            await #expect(throws: ExitCode(EX_NOPERM)) { try await command.run() }
        }
        #expect(out.stderr == "rv: set safety to strict needs owner authentication, which was not given\n")
        #expect(SafetyRun.show(home: home, workspace: nil) == "normal")
    }

    @Test func checkThrowsTheRefusalForCallersThatWordItThemselves() async throws {
        try await withCLIProcess {
            await #expect(throws: OwnerConfirmation.Refused("rv: x needs owner authentication, which was not given")) {
                try await OwnerConfirmation.check("x")
            }
        }
    }
}
