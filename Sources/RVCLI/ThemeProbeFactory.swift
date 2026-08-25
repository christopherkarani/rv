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
        environment: [String: String]
    ) -> ThemeProbe {
        ThemeProbe(
            terminal: TTYPair(stdinIsTTY: stdinIsTTY, stdoutIsTTY: stdoutIsTTY),
            forbid: OutputForbid(
                json: jsonFlag,
                robot: robotFlag,
                plain: plainFlag,
                ci: environment["CI"] != nil,
                noColor: OutputForbid.NoColor(
                    flag: noColorFlag,
                    env: environment["NO_COLOR"] != nil,
                    termDumb: environment["TERM"] == "dumb"
                )
            ),
            columns: stdoutColumns(stdoutIsTTY: stdoutIsTTY)
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
            stdinIsTTY: isatty(STDIN_FILENO) != 0,
            stdoutIsTTY: isatty(STDOUT_FILENO) != 0,
            environment: ProcessInfo.processInfo.environment
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
    guard ioctl(STDOUT_FILENO, request, &size) == 0, size.ws_col > 0 else {
        return 80
    }
    return Int(size.ws_col)
}
