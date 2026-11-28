import RVDomain

/// Q1's new names (`rv why`, `rv unlock`, `rv guard <host>`, `rv watch
/// <host>`, `rv secrets add`) run the command they name before help, the
/// typo check or the parser sees the arguments, so each prints the same
/// bytes and exits with the same code as its old spelling. The table is
/// `CommandVocabulary.Alias`.
public enum CommandAlias {
    /// `arguments` with a leading alias rewritten, also after `rv help`.
    /// An alias missing its host is left as typed: `refusal` answers it.
    public static func expanded(_ arguments: [String]) -> [String] {
        let help = CommandVocabulary.Command.help.rawValue
        if arguments.first == help {
            let rest = Array(arguments.dropFirst())
            if let alias = CommandVocabulary.Alias.leading(rest), alias.runs.contains(CommandVocabulary.Alias.hostSlot) {
                // `rv help guard`: the page of what it runs, `rv host mode`.
                let page = alias.runs.prefix { $0 != CommandVocabulary.Alias.hostSlot }
                return [help] + page + rest.dropFirst(alias.words.count)
            }
            return [help] + expanded(rest)
        }
        switch CommandVocabulary.expand(arguments) {
        case .unchanged, .missingArgument: return arguments
        case .expanded(let rewritten): return rewritten
        }
    }

    /// `rv guard` alone: name the agent, the way `rv host` lists them.
    static func refusal(_ arguments: [String]) -> String? {
        guard case .missingArgument(let alias) = CommandVocabulary.expand(arguments) else { return nil }
        let program = CommandVocabulary.program
        let typed = ([program] + alias.words).joined(separator: " ")
        return "\(program): \(typed) needs an agent, as in \(typed) claude. \(CommandVocabulary.Command.host.invocation) lists them.\n"
    }

    /// The words an alias starts with, for the typo check: `why`, `unlock`,
    /// `guard`, `watch` (`secrets add` starts with a command).
    static var leadingWords: [String] {
        CommandVocabulary.Alias.allCases.compactMap(\.words.first)
    }
}
