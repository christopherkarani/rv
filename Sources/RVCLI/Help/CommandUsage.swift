import ArgumentParser
import RVPresentation

/// A command's usage rows, declared in the command beside its `@Option` /
/// `@Flag` / `@Argument` properties. Help pages list them in the order the
/// parent's `subcommands` names the commands; tests parse every row with
/// the real parser and check that every option the parser knows is in one.
protocol CommandUsage: ParsableCommand {
    /// `rv …` rows: a spelling the parser accepts, with an optional note.
    static var usage: [HelpRow] { get }
}

enum UsageRows {
    /// The usage rows of every command under `parent`, in parser order. A
    /// command without rows of its own contributes its subcommands' rows.
    static func under(_ parent: ParsableCommand.Type) -> [HelpRow] {
        parent.configuration.subcommands.flatMap { command -> [HelpRow] in
            if let declared = command as? any CommandUsage.Type { return declared.usage }
            return under(command)
        }
    }
}
