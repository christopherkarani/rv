import Foundation
import RVDomain
import RVIsolation
import RVPolicy
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The imperative shell of `rv box tidy`: reads the machine
/// (`WorkspaceHosts.tidyScan`), asks the one yes, then moves leftovers to
/// the trash (`BoxTidy.apply`). macOS only, like every box.
enum BoxTidyRun {
    /// The words `rv box tidy` takes after `tidy`.
    static let words: Set = ["--yes", "-y", "--help", "-h"]

    static func run(yes: Bool) throws {
        #if !os(macOS)
        try BoxRun.refuse(BoxPlan.linuxHostRefusal)
        #else
        guard let home = BoxRun.passwdHome() else { try BoxRun.refuse(BoxPlan.noHome) }
        let shownHome = BoxRun.canonical(home.rawValue)
        let trash = BoxTrash(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let now = Date()
        let plan = BoxTidy.plan(WorkspaceHosts.tidyScan(trash: trash), now: now)
        write(BoxTidyRender.summary(plan, home: shownHome))
        if let hold = plan.hold {
            write(BoxTidyRender.holdText(hold, home: shownHome))
            write(BoxTidyRender.done(apply(plan, moving: false, trash: trash, now: now)))
            return
        }
        guard plan.moves.isEmpty == false else {
            write(BoxTidyRender.done(apply(plan, moving: false, trash: trash, now: now)))
            return
        }
        var moving = yes
        if moving == false {
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                write(BoxTidyRender.notAsked)
                write(BoxTidyRender.done(apply(plan, moving: false, trash: trash, now: now)))
                return
            }
            write(BoxTidyRender.question(plan))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            moving = answer == "y" || answer == "yes"
            if moving == false { write(BoxTidyRender.declined) }
        }
        write(BoxTidyRender.done(apply(plan, moving: moving, trash: trash, now: now)))
        #endif
    }

    #if os(macOS)
    private static func apply(_ plan: BoxTidyPlan, moving: Bool, trash: BoxTrash, now: Date) -> BoxTidyOutcome {
        BoxTidy.apply(plan, moving: moving, trash: trash, now: now, detach: detach)
    }

    /// `hdiutil detach <device>`, never `-force`: an image something still
    /// uses stays attached. Bounded, since DiskArbitration can wedge.
    private static func detach(_ device: String) -> Bool {
        guard device.hasPrefix("/dev/disk"), device.contains("\0") == false else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", device]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
    #endif

    private static let stdoutPalette = BoxInk.palette(
        isTerminal: isatty(STDOUT_FILENO) == 1, environment: CLIProcess.environment())

    private static func write(_ text: String) {
        guard text.isEmpty == false else { return }
        FileHandle.standardOutput.write(Data(BoxInk.paint(text, palette: stdoutPalette).utf8))
    }
}
