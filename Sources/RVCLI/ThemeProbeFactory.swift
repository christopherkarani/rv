import Darwin
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
            stdinIsTTY: stdinIsTTY,
            stdoutIsTTY: stdoutIsTTY,
            jsonFlag: jsonFlag,
            robotFlag: robotFlag,
            plainFlag: plainFlag,
            noColorFlag: noColorFlag,
            ci: environment["CI"] != nil,
            noColorEnv: environment["NO_COLOR"] != nil,
            termDumb: environment["TERM"] == "dumb",
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
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
        return 80
    }
    return Int(size.ws_col)
}
