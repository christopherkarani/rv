import RVDomain

/// Observe only: proof that a shell command does nothing but read.
///
/// `ObserveFloor` escalates a command naming one of rv's wiring files to
/// enforce, where the judge scores the whole line; `codesign -dv` of rv's
/// install was blocked that way. Wiring files hold no secret, and an
/// observe host already allows these verbs on any other path, so a proven
/// read is observed instead. rv's config is not covered: it is checked
/// before this proof and always holds.
///
/// The proof is a closed table: every chain segment must be one of the
/// verbs below, written plainly. An unknown verb, an assignment or
/// wrapper prefix, quoting, expansion, globbing, a redirect, a subshell,
/// or a flag outside a verb's read-only set is no proof, and the caller
/// escalates exactly as before.
enum ObserveReadProof {
    static func proves(_ command: ShellCommand, analysis: SemanticAnalysis) -> Bool {
        switch analysis {
        case .unknown:
            break
        case .filesystem(let action) where action.operationKind == .read:
            break
        case .filesystem, .git, .wrapper, .unwrapLimited:
            return false
        }
        // Every scalar, not every Character: `"\r\n"` and `">\u{301}"` are
        // one Character each, yet the shell reads the `\r` or `>` byte.
        guard command.rawValue.unicodeScalars.allSatisfy(plain.contains) else { return false }
        let segments = shellChainSegments(command.rawValue)
        return segments.isEmpty == false && segments.allSatisfy(readsOnly)
    }

    /// Precondition: the segment holds only `plain` scalars.
    private static func readsOnly(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return false }
        let arguments = Array(words.dropFirst())
        switch verb {
        // No flag of these writes; every operand is read.
        case "ls", "stat", "cat", "head", "tail", "wc":
            return true
        case "codesign":
            return codesignInspects(arguments)
        case _ where isRVProgram(verb):
            return rvReports(arguments)
        // `log show` only reads the unified log; `log erase`/`config` write.
        case "log":
            return arguments.first == "show"
        default:
            return false
        }
    }

    /// Display and verify only. `-s`, `-f`, `--remove-signature` sign or
    /// strip; `-r <file>`, `--entitlements <file>` and
    /// `--extract-certificates` write files; every other flag is refused.
    private static func codesignInspects(_ arguments: [String]) -> Bool {
        var inspects = false
        for argument in arguments where argument.hasPrefix("-") {
            if argument.count > 1, argument.dropFirst().allSatisfy({ $0 == "d" || $0 == "v" }) {
                inspects = true
            } else if argument == "--display" || argument == "--verify" {
                inspects = true
            } else if !codesignModifiers.contains(argument), !isVerboseLevel(argument) {
                return false
            }
        }
        return inspects
    }

    /// rv itself, by name or at its installed path (`~/.local/bin/rv`,
    /// `/Users/<you>/.local/bin/rv`): running the binary writes nothing
    /// there, and an agent checking its own install (`rv --version`,
    /// `rv doctor`) was escalated to enforce and blocked by the judge.
    private static func isRVProgram(_ verb: String) -> Bool {
        verb == "rv" || verb == "~/.local/bin/rv"
            || (verb.hasPrefix("/") && verb.hasSuffix("/.local/bin/rv"))
    }

    /// rv subcommands that only report: no write, no change to the gate.
    /// Exact argument lists; anything else (setup, a host mode change,
    /// uninstall, an unknown flag) is no proof.
    private static func rvReports(_ arguments: [String]) -> Bool {
        let json = arguments.last == "--json" ? Array(arguments.dropLast()) : arguments
        return rvReportForms.contains(json)
    }

    private static let rvReportForms: Set<[String]> = [
        ["--version"], ["version"], ["--help"], ["help"], ["doctor"], ["blocks"],
        ["host", "list"], ["service", "status"],
    ]

    private static let codesignModifiers: Set<String> = ["--verbose", "--deep", "--strict"]

    private static func isVerboseLevel(_ argument: String) -> Bool {
        guard argument.hasPrefix("--verbose=") else { return false }
        let level = argument.dropFirst("--verbose=".count)
        return level.isEmpty == false && level.allSatisfy(\.isASCIIDigitCharacter)
    }

    /// The only scalars a proof may contain: ASCII letters and digits, space,
    /// tab, the word and path characters `.` `_` `/` `~` `=` `:` `,` `+`
    /// `@` `%` `-` (each one literal character, not a range), and the
    /// chain separators `;`, `&`, `|` (each segment
    /// must then prove itself). Everything else is refused: expansion,
    /// quoting, redirects, subshells, grouping, escapes, comments, history,
    /// globs, any line break, and every non-ASCII scalar (combining marks,
    /// joiners, look-alike spaces).
    private static let plain: Set<Unicode.Scalar> = {
        var scalars = Set<Unicode.Scalar>()
        for range in [("a", "z"), ("A", "Z"), ("0", "9")] as [(Unicode.Scalar, Unicode.Scalar)] {
            for value in range.0.value...range.1.value {
                if let scalar = Unicode.Scalar(value) { scalars.insert(scalar) }
            }
        }
        scalars.formUnion(" \t._/~=:,+@%-;&|".unicodeScalars)
        return scalars
    }()
}

private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}
