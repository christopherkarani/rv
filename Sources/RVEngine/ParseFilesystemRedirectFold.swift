import RVDomain

/// The dispatcher-owned redirect fold: the single module that strips
/// shell redirect words before a writer verb scan and unions the
/// redirect destinations after it. Depth lives at this seam — every
/// verb parser below the dispatcher sees redirect-stripped argv and
/// returns only its own destinations, so a redirect-coverage fix lands
/// once here instead of once per verb (leverage/locality).
///
/// The shell applies redirects before the verb runs, so the union
/// survives every verb outcome: success, `--help`, and parse failure
/// alike. A verb that claims nothing leaves the redirect-only claim,
/// which is an overwrite (the shell truncated the target). A pure
/// read claim (`cat`) folds the same way: the redirect target is the
/// write, so it replaces the read sources as an overwrite instead of
/// riding them as a read.
struct WriterRedirectFold {
    /// Verb argv with redirect syntax removed, ready for the verb scan.
    let stripped: Argv
    /// Output-redirect destinations in command order. A dangling
    /// operator anywhere zeroes the set, matching `parseRedirectOnly`.
    let redirectDests: [String]

    init(_ argv: Argv) {
        stripped = Argv(
            program: argv.program,
            args: stripWriterRedirectWords(argv.args)
        )
        redirectDests = parseRedirectOnly(argv)?.paths ?? []
    }

    /// Folds one verb result (nil on help/failure/no-claim) with the
    /// redirect destinations: append on a verb claim, redirect-only
    /// overwrite without one, read claims promote to that overwrite.
    func union(_ verb: ParsedFilesystemCommand?) -> ParsedFilesystemCommand? {
        guard var verb else {
            return redirectOnly
        }
        if verb.operation == .read, redirectDests.isEmpty == false {
            return redirectOnly
        }
        verb.paths += redirectDests
        return verb
    }

    private var redirectOnly: ParsedFilesystemCommand? {
        guard redirectDests.isEmpty == false else { return nil }
        return ParsedFilesystemCommand(
            operation: .overwrite,
            paths: redirectDests,
            recursive: false,
            force: false,
            mode: nil
        )
    }
}

/// Removes redirect syntax from writer argv so operators and their targets
/// never pollute the operand scan. Output operators drop with their target
/// (the union re-adds the target); input/heredoc operators drop WITHOUT
/// their target — the target stays an operand, which over-approximates in
/// the fail-closed direction and cannot eat a quoted metachar operand the
/// way target-eating would. Attached input words (`<f`, `<<EOF`) drop whole
/// (their target is inseparable); fd dups/closes drop whole (no file).
func stripWriterRedirectWords(_ args: [String]) -> [String] {
    var clean: [String] = []
    var index = args.startIndex
    while index < args.endIndex {
        let word = args[index]
        if isRedirectOperator(word) {
            args.formIndex(after: &index)
            if index < args.endIndex {
                args.formIndex(after: &index)
            }
            continue
        }
        if RedirectOperatorLexer.isAttachedRedirectWord(word) {
            args.formIndex(after: &index)
            continue
        }
        clean.append(word)
        args.formIndex(after: &index)
    }
    return clean
}
