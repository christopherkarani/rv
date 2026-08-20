import Darwin
import Foundation
import RVPresentation
import RVTUI
import RVTheme

protocol SetupCeremonyClock: Sendable {
    func sleep(nanoseconds: UInt64)
}

struct LiveSetupCeremonyClock: SetupCeremonyClock {
    func sleep(nanoseconds: UInt64) {
        guard nanoseconds > 0 else { return }
        let seconds = Double(nanoseconds) / 1_000_000_000
        Thread.sleep(forTimeInterval: seconds)
    }
}

struct ZeroSetupCeremonyClock: SetupCeremonyClock {
    func sleep(nanoseconds: UInt64) {}
}

enum SetupCeremonyPlayer {
    /// Paints frames with pacing. Returns the final frame text (no cursor codes).
    static func play(
        frames: [SetupCeremonyFrame],
        palette: Palette,
        clock: any SetupCeremonyClock,
        animate: Bool,
        write: (String) -> Void
    ) -> String {
        let renderer = SetupRenderer()
        guard let last = frames.last else { return "" }
        if animate == false {
            let lines = renderer.render(last, palette: palette)
            let text = PrettyWriter.join(lines)
            write(text)
            return text
        }

        var previousLineCount = 0
        for frame in frames {
            let lines = renderer.render(frame, palette: palette)
            if previousLineCount > 0 {
                write(cursorUp(previousLineCount))
            }
            for line in lines {
                write(clearLine() + line + "\n")
            }
            // FileHandle writes can buffer; without flush the TTY stays blank for the sleeps.
            fflush(stdout)
            previousLineCount = lines.count
            clock.sleep(nanoseconds: frame.pauseNanoseconds)
        }
        return PrettyWriter.join(renderer.render(last, palette: palette))
    }

    private static func cursorUp(_ lines: Int) -> String {
        guard lines > 0 else { return "" }
        return "\u{001B}[\(lines)A"
    }

    private static func clearLine() -> String {
        "\u{001B}[2K\r"
    }
}
