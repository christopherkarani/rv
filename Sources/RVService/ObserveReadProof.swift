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
        let segments = shellChainSegments(command.rawValue)
        return segments.isEmpty == false && segments.allSatisfy(readsOnly)
    }

    static func readsOnly(_ segment: String) -> Bool {
        if segment.contains(where: { notPlain.contains($0) }) { return false }
        let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return false }
        let arguments = Array(words.dropFirst())
        switch verb {
        // No flag of these writes; every operand is read.
        case "ls", "stat", "cat", "head", "tail", "wc":
            return true
        case "codesign":
            return codesignInspects(arguments)
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

    private static let codesignModifiers: Set<String> = ["--verbose", "--deep", "--strict"]

    private static func isVerboseLevel(_ argument: String) -> Bool {
        guard argument.hasPrefix("--verbose=") else { return false }
        let level = argument.dropFirst("--verbose=".count)
        return level.isEmpty == false && level.allSatisfy(\.isASCIIDigitCharacter)
    }

    /// Shell syntax that changes what runs or what is written: expansion,
    /// quoting, redirects, subshells, grouping, escapes, comments, history
    /// and globs (zsh's `^`/`#` included).
    private static let notPlain: Set<Character> = [
        "$", "`", "'", "\"", "\\", "<", ">", "(", ")", "{", "}", ";", "&", "|",
        "*", "?", "[", "]", "^", "#", "!", "\n", "\r",
    ]
}

private extension Character {
    var isASCIIDigitCharacter: Bool { ("0"..."9").contains(self) }
}
