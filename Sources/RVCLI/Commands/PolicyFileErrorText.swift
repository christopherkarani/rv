import Foundation
import RVDomain
import RVPolicy

/// Words for a policy file that does not load: the file and line, what is
/// wrong, and the fix. Replaces the old one-size "invalid policy file".
enum PolicyFileErrorText {
    /// `  ✕ <file>:<line>  <problem>` then `  → <fix>`.
    static func text(_ problem: PolicyDocumentProblem, file: String) -> String {
        problem.lines(file: DisplayedText.field(file)).map { "  \($0)\n" }.joined()
    }

    static func text(_ failure: PolicyFileFailure) -> String {
        let file = displayPath(failure.file)
        switch failure.reason {
        case .parse(let problem):
            return text(problem, file: file)
        case .load(let problem):
            let (what, fix) = loadWords(problem)
            return "  ✕ \(DisplayedText.field(file))  \(what)\n  → \(fix)\n"
        }
    }

    /// `  ✕ No file at <path>`.
    static func missing(_ path: String) -> String {
        "  ✕ No file at \(DisplayedText.field(path))\n"
    }

    /// The layer failures, or the old line when the file changed between
    /// the load and this read (nothing left to point at).
    static func layers(_ failures: [PolicyFileFailure], command: String) -> String {
        guard failures.isEmpty == false else {
            return "rv \(command): invalid policy file\n"
        }
        return failures.map(text).joined()
    }

    /// `~/…` under the home directory, else the path as is.
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        if let home = CLIProcess.home()?.rawValue, home.isEmpty == false {
            let prefix = home.hasSuffix("/") ? home : home + "/"
            if path.hasPrefix(prefix) {
                return "~/" + path.dropFirst(prefix.count)
            }
        }
        return path
    }

    private static func loadWords(_ problem: PolicyLoadStatus.Problem) -> (String, String) {
        switch problem {
        case .notRegularFile:
            return ("is not a regular file, so rv does not read it", "replace it with a plain text file")
        case .symlink:
            return ("is a symlink, which rv does not follow here", "replace the link with the file itself")
        case .tooLarge:
            return ("is larger than rv reads (1 MiB)", "remove rules you no longer need")
        case .notUTF8:
            return ("is not UTF-8 text", "save it as UTF-8")
        case .unreadable:
            return ("cannot be read", "check that you can read it (ls -l)")
        case .unparseable:
            return ("does not parse", "fix the file, or move it aside and save your rules again")
        }
    }
}
