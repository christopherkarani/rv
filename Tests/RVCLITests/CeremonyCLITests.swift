import ArgumentParser
import Foundation
import Testing
import RVPresentation
import RVTheme
@testable import RVCLI

struct CeremonyCLITests {
    @Test func appearance_robotNeverAnimates() throws {
        try withCLIProcess(stdoutIsTTY: true) {
            let resolved = CeremonyCLI.appearance(
                json: false,
                robot: true,
                plain: false,
                noColor: false
            )
            #expect(resolved.appearance == .robot)
            #expect(resolved.animate == false)
        }
    }

    @Test func appearance_jsonNeverAnimates() throws {
        try withCLIProcess(stdoutIsTTY: true) {
            let resolved = CeremonyCLI.appearance(
                json: true,
                robot: false,
                plain: false,
                noColor: false
            )
            #expect(resolved.appearance == .robot)
            #expect(resolved.animate == false)
        }
    }

    @Test func appearance_prettyAnimatesOnlyWhenStdoutIsTTY() throws {
        try withCLIProcess(
            environment: ["TERM": "xterm"],
            stdinIsTTY: true,
            stdoutIsTTY: true
        ) {
            let resolved = CeremonyCLI.appearance(
                json: false,
                robot: false,
                plain: true,
                noColor: true
            )
            if case .pretty = resolved.appearance {
                #expect(resolved.animate)
            } else {
                Issue.record("expected pretty appearance on TTY without CI")
            }
        }
        try withCLIProcess(
            environment: ["TERM": "xterm"],
            stdinIsTTY: true,
            stdoutIsTTY: false
        ) {
            let resolved = CeremonyCLI.appearance(
                json: false,
                robot: false,
                plain: true,
                noColor: true
            )
            #expect(resolved.animate == false)
        }
    }

    @Test func appearance_ciForcesRobot() throws {
        try withCLIProcess(environment: ["CI": "1"], stdoutIsTTY: true) {
            let resolved = CeremonyCLI.appearance(
                json: false,
                robot: false,
                plain: false,
                noColor: false
            )
            #expect(resolved.appearance == .robot)
            #expect(resolved.animate == false)
        }
    }

    @Test func emit_writesPendingStdoutAndStderrThenThrows() {
        #expect(throws: ExitCode(2)) {
            try CeremonyCLI.emit(
                SetupOutcome(stdout: "out\n", stderr: "err\n", exitCode: 2, emitted: false)
            )
        }
    }

    @Test func emit_skipsAlreadyEmittedStdout() {
        #expect(throws: ExitCode(0)) {
            try CeremonyCLI.emit(
                SetupOutcome(stdout: "already-painted\n", stderr: "", exitCode: 0, emitted: true)
            )
        }
    }

    @Test func emit_emptyStreamsStillThrowsExit() {
        #expect(throws: ExitCode(1)) {
            try CeremonyCLI.emit(SetupOutcome(stdout: "", stderr: "", exitCode: 1))
        }
    }

    @Test func stdoutWriter_writesChunk() {
        CeremonyCLI.stdoutWriter()("ceremony-chunk\n")
    }

    @Test func liveClock_zeroIsNoOp_andPositiveSleeps() {
        LiveSetupCeremonyClock().sleep(nanoseconds: 0)
        LiveSetupCeremonyClock().sleep(nanoseconds: 1_000)
    }

    @Test func ceremonyKind_fromInstallEnvironment() {
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: [:]) == .setup)
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "0"]) == .setup)
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "1"]) == .install)
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "true"]) == .install)
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "YES"]) == .install)
        #expect(SetupCeremonyKind.fromInstallEnvironment(environment: ["RV_FROM_INSTALL": "True"]) == .install)
    }

    @Test func setupCommand_helpText() {
        #expect(Setup.helpText().isEmpty == false)
        #expect(Uninstall.helpText().isEmpty == false)
    }
}
