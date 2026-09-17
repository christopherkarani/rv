#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVTheme
@testable import RVCLI

struct ThemeProbeFactoryTests {
    @Test func make_nonTTYColumnsAre80() {
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: false,
            stdoutIsTTY: false,
            environment: [:]
        )
        #expect(probe.columns == 80)
        #expect(probe.terminal.stdinIsTTY == false)
        #expect(probe.terminal.stdoutIsTTY == false)
        #expect(probe.forbid.ci == false)
    }

    @Test func make_honorsForbidFlagsAndEnvironment() {
        let probe = ThemeProbeFactory.make(
            jsonFlag: true,
            robotFlag: true,
            plainFlag: true,
            noColorFlag: true,
            stdinIsTTY: true,
            stdoutIsTTY: false,
            environment: ["CI": "1", "NO_COLOR": "1", "TERM": "dumb"]
        )
        #expect(probe.forbid.json)
        #expect(probe.forbid.robot)
        #expect(probe.forbid.plain)
        #expect(probe.forbid.ci)
        #expect(probe.forbid.noColor.flag)
        #expect(probe.forbid.noColor.env)
        #expect(probe.forbid.noColor.termDumb)
        #expect(probe.columns == 80)
    }

    @Test func make_ciAbsentAndColorfulTerm() {
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: true,
            stdoutIsTTY: false,
            environment: ["TERM": "xterm-256color"]
        )
        #expect(probe.forbid.ci == false)
        #expect(probe.forbid.noColor.env == false)
        #expect(probe.forbid.noColor.termDumb == false)
    }

    @Test func live_readsCLIProcessOverrides() throws {
        try withCLIProcess(
            environment: ["CI": "true", "NO_COLOR": "1", "TERM": "dumb"],
            stdinIsTTY: true,
            stdoutIsTTY: false
        ) {
            let probe = ThemeProbeFactory.live(
                jsonFlag: false,
                robotFlag: true,
                plainFlag: false,
                noColorFlag: false
            )
            #expect(probe.terminal.stdinIsTTY)
            #expect(probe.terminal.stdoutIsTTY == false)
            #expect(probe.forbid.robot)
            #expect(probe.forbid.ci)
            #expect(probe.forbid.noColor.env)
            #expect(probe.forbid.noColor.termDumb)
            #expect(probe.columns == 80)
        }
    }

    @Test func live_withoutOverrideUsesProcess() {
        let probe = ThemeProbeFactory.live(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false
        )
        #expect(probe.columns >= 1)
    }

    @Test func make_badStdoutFDFallsBackTo80() throws {
        try withCLIProcess(stdoutFileDescriptor: -1) {
            let probe = ThemeProbeFactory.make(
                jsonFlag: false,
                robotFlag: false,
                plainFlag: false,
                noColorFlag: false,
                stdinIsTTY: true,
                stdoutIsTTY: true,
                environment: [:]
            )
            #expect(probe.columns == 80)
        }
    }

    @Test func make_stdoutTTY_ioctlMissFallsBackTo80() {
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: true,
            stdoutIsTTY: true,
            environment: [:]
        )
        #expect(probe.columns >= 1)
    }

    @Test func make_ptyZeroColumnsFallBackTo80() throws {
        try withPTY(columns: 0) { slave in
            try withCLIProcess(stdoutFileDescriptor: slave) {
                let probe = ThemeProbeFactory.make(
                    jsonFlag: false,
                    robotFlag: false,
                    plainFlag: false,
                    noColorFlag: false,
                    stdinIsTTY: true,
                    stdoutIsTTY: true,
                    environment: [:]
                )
                #expect(probe.columns == 80)
            }
        }
    }

    @Test func make_ptyColumnsUseIoctlSuccess() throws {
        try withPTY(columns: 120) { slave in
            try withCLIProcess(stdoutFileDescriptor: slave) {
                let probe = ThemeProbeFactory.make(
                    jsonFlag: false,
                    robotFlag: false,
                    plainFlag: false,
                    noColorFlag: false,
                    stdinIsTTY: true,
                    stdoutIsTTY: true,
                    environment: [:]
                )
                #expect(probe.columns == 120)
            }
        }
    }
}

#if os(Linux)
@_silgen_name("grantpt")
private func c_grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt")
private func c_unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname")
private func c_ptsname(_ fd: Int32) -> UnsafeMutablePointer<CChar>?
#endif

private func withPTY(columns: Int, _ body: (Int32) throws -> Void) throws {
#if os(Linux)
    let master = open("/dev/ptmx", O_RDWR | O_NOCTTY)
#else
    let master = posix_openpt(O_RDWR | O_NOCTTY)
#endif
    try #require(master >= 0)
    defer { _ = close(master) }
#if os(Linux)
    try #require(c_grantpt(master) == 0)
    try #require(c_unlockpt(master) == 0)
    guard let name = c_ptsname(master) else {
        Issue.record("ptsname failed")
        return
    }
#else
    try #require(grantpt(master) == 0)
    try #require(unlockpt(master) == 0)
    guard let name = ptsname(master) else {
        Issue.record("ptsname failed")
        return
    }
#endif
    let slave = open(name, O_RDWR | O_NOCTTY)
    try #require(slave >= 0)
    defer { _ = close(slave) }
    var size = winsize()
    size.ws_row = 24
    size.ws_col = UInt16(columns)
#if canImport(Glibc)
    let request = UInt(TIOCSWINSZ)
#else
    let request = TIOCSWINSZ
#endif
    try #require(ioctl(slave, request, &size) == 0)
    try body(slave)
}
