import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVTheme
import RVUndo

/// `rv undo`: put back what a reset or delete threw away, from the copy
/// rv kept before the command went through (watch mode, or after an
/// unlock). Restoring never overwrites anything, and it is the person's
/// call: it needs a terminal. Listing does not.
struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore what a reset or delete removed, from rv's copy."
    )

    @Argument(help: "Which copy (from --list). Default: the newest one for this repository.")
    var id: String?

    @Flag(name: .long, help: "List the copies rv kept for this repository.")
    var list = false

    func run() async throws {
        let probe = ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false)
        let palette = Palette(for: ColorCapability(probe: probe, mode: .pretty), background: probe.background)
        guard let home = CLIProcess.home() else { try CommandContext.failHomeMissing(command: "undo") }
        let store = UndoStore.inConfigDirectory(RVPolicyPaths.configDirectory(home: home))
        let now = Date()
        for old in store.prune(now: now) { UndoKeeper.dropRef(old) }
        let cwd = FileManager.default.currentDirectoryPath
        let repository = UndoKeeper.repositoryRoot(from: cwd)
        let copies = store.list().filter { repository != nil && $0.repoRoot == repository }
        let screen = UndoScreen(palette: palette, home: home.rawValue)
        if list {
            screen.list(copies).forEach { print($0) }
            if copies.isEmpty { throw ExitCode(2) }
            return
        }
        let picked = id.map { wanted in copies.first { $0.id == wanted } } ?? copies.first
        guard let manifest = picked else {
            screen.none(repository: repository).forEach { print($0) }
            throw ExitCode(2)
        }
        screen.summary(manifest).forEach { print($0) }
        guard manifest.kind != .skipped else { throw ExitCode(1) }
        let tty = TTYCapability(stdinIsTTY: CLIProcess.stdinIsTTY(), stdoutIsTTY: probe.stdoutIsTTY, ci: false)
        guard allowsInteractiveAllowOnce(tty), let repository else {
            screen.needsTerminal().forEach { print($0) }
            throw ExitCode(1)
        }
        print(screen.question(repository: repository), terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer.isEmpty || answer == "y" || answer == "yes" else {
            print("  Nothing changed.")
            return
        }
        do throws(UndoRestoreRefusal) {
            let outcome = try UndoRestore.restore(manifest, from: store, into: repository, now: manifest.createdAt)
            screen.restored(outcome, store: store, manifest: manifest).forEach { print($0) }
        } catch {
            print("  " + screen.paint("\(CommandVocabulary.Glyph.stopped.rawValue) \(error.note)", palette.deny))
            throw ExitCode(1)
        }
    }
}

/// The words of `rv undo`: the v3 "Kept a copy first" frame.
struct UndoScreen {
    private typealias Glyph = CommandVocabulary.Glyph

    let palette: Palette
    let home: String
    var timeZone: TimeZone = .current

    func paint(_ text: String, _ ink: String) -> String {
        palette.colorsEnabled ? ink + text + palette.reset : text
    }

    /// `~/code/app` for a path under home.
    func shown(_ path: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard trimmed.count > 1 else { return path }
        if path == trimmed { return "~" }
        return path.hasPrefix(trimmed + "/") ? "~" + path.dropFirst(trimmed.count) : path
    }

    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `14 files · 2,314 lines`, or the size when lines are unknown.
    static func amount(_ tally: UndoTally) -> String {
        let files = tally.files == 1 ? "1 file" : "\(TryScreen.grouped(tally.files)) files"
        if let lines = tally.lines, lines > 0 { return "\(files) · \(TryScreen.grouped(lines)) lines" }
        if tally.bytes > 0 { return "\(files) · \(UndoSize.words(tally.bytes))" }
        return files
    }

    /// The copy, the command it came before, and what rv kept.
    func summary(_ manifest: UndoManifest) -> [String] {
        let head = "  \(paint(clock(manifest.createdAt), palette.muted))  \(manifest.host)  \(manifest.command)   "
            + paint(manifest.reason.rawValue, palette.muted)
        var lines = ["", head]
        let indent = "         "
        switch manifest.kind {
        case .skipped:
            lines.append(indent + "\(paint(Glyph.rv.rawValue, palette.heading)) rv kept no copy.")
        case .git where manifest.tally.files == 0:
            let head = manifest.git.map { String($0.head.prefix(7)) } ?? ""
            lines.append(indent + "\(paint(Glyph.rv.rawValue, palette.heading)) rv kept a copy first: HEAD at \(head)")
        case .git, .files:
            lines.append(indent + "\(paint(Glyph.rv.rawValue, palette.heading)) rv kept a copy first: \(Self.amount(manifest.tally))")
        }
        lines += manifest.notes.map { indent + paint($0, palette.muted) }
        lines.append("")
        return lines
    }

    func question(repository: String) -> String {
        "  Restore into \(shown(repository))?  \(paint("[Y/n]", palette.muted)) "
    }

    func restored(_ outcome: UndoRestoreOutcome, store: UndoStore, manifest: UndoManifest) -> [String] {
        let done = paint("\(Glyph.done.rawValue) Back,", palette.allow)
        switch outcome {
        case .branch(let branch):
            return ["  \(done) on branch \(paint(branch, palette.heading)). Nothing was overwritten."]
        case .files(let restored, let left):
            var lines = ["  \(done) \(restored == 1 ? "1 file" : "\(TryScreen.grouped(restored)) files"). Nothing was overwritten."]
            if left.isEmpty == false {
                lines.append("  Already there, so left alone: \(left.joined(separator: ", ")).")
                lines.append("  Their copy is in \(shown(store.dataDirectory(of: manifest).path)).")
            }
            return lines
        }
    }

    func list(_ copies: [UndoManifest]) -> [String] {
        guard copies.isEmpty == false else { return none(repository: nil) }
        return copies.map { manifest in
            "  \(paint(clock(manifest.createdAt), palette.muted))  \(manifest.host)  \(manifest.command)   "
                + paint(manifest.kind == .skipped ? "no copy" : Self.amount(manifest.tally), palette.muted)
                + "   \(manifest.id)"
        }
    }

    func none(repository: String?) -> [String] {
        let place = repository.map { " for \(shown($0))" } ?? " here"
        return ["  \(paint(Glyph.rv.rawValue, palette.heading)) rv has no copies\(place) from the last 7 days."]
    }

    func needsTerminal() -> [String] {
        [
            "  Restoring is the person's call, at a terminal.",
            "  " + paint("\(Glyph.next.rawValue) \(CommandVocabulary.Command.undo.invocation)", palette.heading),
        ]
    }
}
