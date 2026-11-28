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

    /// Nothing changes without a yes: the typed `y`, or `--yes`. `--yes`
    /// is for scripts and agents: an agent may run `rv box tidy --yes`,
    /// since tidy only ever moves to the 7-day trash and never touches a
    /// box that may hold unsaved work.
    ///
    /// The machine is read twice: once for the question, and again after
    /// the yes. Only what was asked about and is still a leftover moves
    /// (`BoxTidy.confirm`), and attachment is checked once more right
    /// before each rename and before each trash entry is emptied.
    static func run(yes: Bool) throws {
        #if !os(macOS)
        try BoxRun.refuse(BoxPlan.linuxHostRefusal)
        #else
        guard let home = BoxRun.passwdHome() else { try BoxRun.refuse(BoxPlan.noHome) }
        let shownHome = BoxRun.canonical(home.rawValue)
        let trash = BoxTrash(configDirectory: RVPolicyPaths.configDirectory(home: home))
        let asked = BoxTidy.plan(WorkspaceHosts.tidyScan(trash: trash), now: Date())
        write(BoxTidyRender.summary(asked, home: shownHome))
        if let hold = asked.hold {
            write(BoxTidyRender.holdText(hold, home: shownHome))
            return
        }
        guard asked.isEmpty == false else { return }
        if yes == false {
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                write(BoxTidyRender.notAsked)
                return
            }
            write(BoxTidyRender.question(asked))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                write(BoxTidyRender.declined)
                return
            }
        }
        // The answer may have taken minutes: a box may have started, or
        // claimed an image, meanwhile. Read the machine again.
        let now = Date()
        let confirmed = BoxTidy.confirm(asked, rescanned: BoxTidy.plan(WorkspaceHosts.tidyScan(trash: trash), now: now))
        if let hold = confirmed.hold {
            write(BoxTidyRender.holdText(hold, home: shownHome))
            return
        }
        let outcome = BoxTidy.apply(
            confirmed, trash: trash, now: now,
            attachedNow: WorkspaceHosts.attachedImageNames, detach: detach)
        write(BoxTidyRender.done(outcome, asked: asked.moves.count + asked.expired.count))
        #endif
    }

    #if os(macOS)
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
