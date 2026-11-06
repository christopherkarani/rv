#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVTheme

enum ThemeProbeFactory {
    static func make(
        jsonFlag: Bool,
        robotFlag: Bool,
        plainFlag: Bool,
        noColorFlag: Bool,
        stdinIsTTY: Bool,
        stdoutIsTTY: Bool,
        environment: [String: String],
        terminal channel: any TerminalQueryChannel = UnavailableTerminalChannel()
    ) -> ThemeProbe {
        let terminal = TTYPair(stdinIsTTY: stdinIsTTY, stdoutIsTTY: stdoutIsTTY)
        let forbid = OutputForbid(
            json: jsonFlag,
            robot: robotFlag,
            plain: plainFlag,
            ci: environment["CI"] != nil,
            noColor: OutputForbid.NoColor(
                flag: noColorFlag,
                env: environment["NO_COLOR"] != nil,
                termDumb: environment["TERM"] == "dumb"
            )
        )
        return ThemeProbe(
            terminal: terminal,
            forbid: forbid,
            columns: stdoutColumns(stdoutIsTTY: stdoutIsTTY),
            background: BackgroundProbe.detect(
                preference: ThemePreference(environment: environment),
                terminal: terminal,
                forbid: forbid,
                channel: channel
            )
        )
    }

    static func live(
        jsonFlag: Bool,
        robotFlag: Bool,
        plainFlag: Bool,
        noColorFlag: Bool
    ) -> ThemeProbe {
        make(
            jsonFlag: jsonFlag,
            robotFlag: robotFlag,
            plainFlag: plainFlag,
            noColorFlag: noColorFlag,
            stdinIsTTY: CLIProcess.stdinIsTTY(),
            stdoutIsTTY: CLIProcess.stdoutIsTTY(),
            environment: CLIProcess.environment(),
            terminal: CLIProcess.terminalQueryChannel()
        )
    }
}

private func stdoutColumns(stdoutIsTTY: Bool) -> Int {
    guard stdoutIsTTY else { return 80 }
    var size = winsize()
#if canImport(Glibc)
    let request = UInt(TIOCGWINSZ)
#else
    let request = TIOCGWINSZ
#endif
    guard ioctl(CLIProcess.stdoutFileDescriptor(), request, &size) == 0, size.ws_col > 0 else {
        return 80
    }
    return Int(size.ws_col)
}
