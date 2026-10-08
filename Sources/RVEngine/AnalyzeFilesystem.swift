import RVDomain

/// Pure filesystem classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeFilesystem(
    _ command: ExecutingCommand,
    context: FilesystemAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command.rawValue).rawValue
    if view.isEmpty { return .unknown }
    guard let single = singleEffectiveSegment(view) else { return .unknown }
    let tokens = tokenizeFilesystemWords(single)
    guard let parsed = parseFilesystemCommand(tokens) else {
        // C-F7 (single): an unnameable verb fails closed, mirroring the
        // chain path, instead of returning unknown → allow. This also
        // closes the pre-existing gap for dynamic-head singles (`$CMD -o
        // /outside` parsed nothing and allowed).
        if let head = tokens.first,
            isDynamicToken(head) || isGlobBraceHead(head),
            let outside = dynamicOutsideTarget(head, context: context, head: true)
        {
            return .filesystem(.overwrite(targets: [outside]))
        }
        return .unknown
    }
    guard let action = filesystemAction(parsed: parsed, context: context) else {
        return .unknown
    }
    return .filesystem(claimDynamicVerb(action, tokens: tokens, context: context))
}

/// Parses every chain segment as a filesystem command, in order.
/// Unparseable (non-filesystem, unknown-syntax) segments are skipped: pack
/// patterns still cover the full text, and the policy stage evaluates each
/// parsed action. Dynamic segments parse too: static paths classify
/// normally and dynamic mutation paths fail closed as outside. Used by the
/// apply stage so a benign prefix cannot hide a risky later segment
/// (Step 8B §24).
func parseFilesystemSegments(
    _ view: String,
    context: FilesystemAnalysisContext,
    assignmentValues: [String] = []
) -> [FilesystemAction] {
    // Straight-line `cd`/`pushd`/`popd` tracking: each segment parses
    // against the pre-segment cwd, then updates the tracker for later
    // segments, so `cd /tmp && touch evil` resolves `evil` outside.
    var tracker = DirectoryTracker(
        working: context.workingDirectory?.rawValue,
        home: context.homeDirectory?.rawValue
    )
    var actions: [FilesystemAction] = []
    let segments = splitSegments(view).flatMap { piece -> [String] in
        // Inner/grouping prefixes never passed through matching, so their
        // provenance is intact: a substitution-carrying VALUE is not a
        // command and only its inners evaluate (M-24).
        let (values, tail) = ShellPipeline.splitAssignmentPrefixValues(piece)
        var out: [String] = []
        for value in values {
            out.append(contentsOf: splitSegments(value).dropFirst())
        }
        out.append(contentsOf: splitSegments(tail))
        return out
    }
    // Top-level values were already rewritten to `VALUE ; TAIL` by matching,
    // so a bare `$(...)` segment is textually identical whether it was a
    // VALUE or a typed standalone (whose output re-executes — genuinely
    // C-F7). The threaded budget tells them apart: each collected value
    // excuses at most one bare segment, inners already being siblings.
    var budget = assignmentValues
    let claimed = segments.filter { segment in
        guard isBareSubstitution(segment),
            let match = budget.firstIndex(where: { assignmentValueMatches($0, segment) })
        else {
            return true
        }
        budget.remove(at: match)
        return false
    }
    for segment in claimed {
        let tokens = tokenizeFilesystemWords(segment)
        var segmentContext = context
        segmentContext.workingDirectory = tracker.working.flatMap(WorkingDirectory.init(validating:))
        if let parsed = parseFilesystemCommand(tokens),
            let action = filesystemAction(parsed: parsed, context: segmentContext)
        {
            actions.append(claimDynamicVerb(action, tokens: tokens, context: segmentContext))
        } else if let head = tokens.first,
            isDynamicToken(head) || isGlobBraceHead(head),
            let outside = dynamicOutsideTarget(head, context: segmentContext, head: true)
        {
            // C-F7: a dynamic argv0 (`$(...)`, backticks, `$VAR`) hides the
            // verb itself, so no parser can claim the segment. Glob/brace
            // heads (`[c]url`, `{curl,}`) hide it the same way. The
            // operation cannot be established — fail closed as an outside
            // overwrite (Step 8B §10) rather than skipping into unknown →
            // allow. Home-alias heads (`$HOME/bin/tool`) expand lexically
            // and stay unclaimed via isDynamicToken. Backslash-only heads
            // never reach here unrecognized: dispatch unescapes pairs first.
            actions.append(.overwrite(targets: [outside]))
        }
        tracker.apply(tokens: tokens)
    }
    return actions
}

private func filesystemAction(
    parsed: ParsedFilesystemCommand,
    context: FilesystemAnalysisContext
) -> FilesystemAction? {
    // Dynamic-blind reads stay unclaimed: `cat $f` cannot resolve its target
    // and static outside-reads already allow, so claiming would only add
    // noise. Mutations below fail closed instead.
    if parsed.operation == .read, parsed.paths.contains(where: isDynamicToken) {
        return nil
    }
    let targets = parsed.paths.map {
        dynamicOutsideTarget($0, context: context)
            ?? classifyFilesystemTarget($0, context: context)
    }
    switch parsed.operation {
    case .delete:
        return .delete(targets: targets, recursive: parsed.recursive, force: parsed.force)
    case .move:
        guard let destination = targets.last, targets.count >= 2 else {
            return nil
        }
        return .move(sources: Array(targets.dropLast()), destination: destination)
    case .overwrite:
        return .overwrite(targets: targets)
    case .chmod:
        return .chmod(targets: targets, mode: parsed.mode, recursive: parsed.recursive)
    case .create:
        return .create(targets: targets)
    case .read:
        return .read(targets: targets)
    }
}

public func analyzeFilesystem(
    _ command: ShellCommand,
    context: FilesystemAnalysisContext = .empty
) -> SemanticAnalysis {
    analyzeFilesystem(ExecutingCommand(rawValue: command.rawValue), context: context)
}

/// Apparent path operands for a parseable filesystem command. Empty if unsupported.
public func filesystemApparentPaths(_ command: ShellCommand) -> [String] {
    let view = Normalize.matchingView(of: command).rawValue
    if view.isEmpty { return [] }
    guard let single = singleEffectiveSegment(view) else { return [] }
    let tokens = tokenizeFilesystemWords(single)
    let paths = parseFilesystemCommand(tokens)?.paths ?? []
    return paths.filter { isDynamicToken($0) == false }
}

private func isDynamicToken(_ token: String) -> Bool {
    // Home aliases contain `$` but are expanded lexically, not dynamically.
    // Exempt them so `echo hi > $HOME/.ssh/config` is not treated as unknown.
    if isHomeAliasPath(token) { return false }
    return token.contains("$") || token.contains("`")
}

/// True when `segment` is exactly one substitution span: `$(...)` with the
/// opener closing at the very end, or a single backtick pair. Affixed
/// spans (`pre$(a)post`) and concatenations (`$(a)$(b)`) are not bare.
private func isBareSubstitution(_ segment: String) -> Bool {
    let text = segment.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("$("), text.hasSuffix(")"), text.count >= 4 {
        var depth = 0
        var quote: Character?
        var index = text.index(text.startIndex, offsetBy: 1)
        while index < text.endIndex {
            let char = text[index]
            if let current = quote {
                if char == current { quote = nil }
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == "(" {
                depth += 1
            } else if char == ")" {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index) == text.endIndex
                }
            }
            text.formIndex(after: &index)
        }
        return false
    }
    if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 {
        return text.dropFirst().dropLast().contains("`") == false
    }
    return false
}

/// True when budget value `value` excuses bare segment `segment`. Values are
/// collected pre-masking while segments come from the matched view, where a
/// whole-token outer quote layer is stripped (`X="$(a)"` budgets `"$(a)"`
/// for segment `$(a)`); that one layer is tolerated.
private func assignmentValueMatches(_ value: String, _ segment: String) -> Bool {
    if value == segment { return true }
    guard value.count >= 2,
        let first = value.first,
        first == "\"" || first == "'",
        value.last == first
    else {
        return false
    }
    return String(value.dropFirst().dropLast()) == segment
}

/// M-04: a redirect-only parse claims the redirect but says nothing about a
/// dynamic verb (`$CMD > ./inside` parsed as an inside overwrite while the
/// verb itself could be anything). Union the C-F7 outside target into the
/// parsed action so the unknown verb fails closed instead of riding the
/// redirect's verdict. Static heads return the action unchanged.
private func claimDynamicVerb(
    _ action: FilesystemAction,
    tokens: [String],
    context: FilesystemAnalysisContext
) -> FilesystemAction {
    guard let head = tokens.first,
        isDynamicToken(head) || isGlobBraceHead(head),
        let outside = dynamicOutsideTarget(head, context: context, head: true)
    else {
        return action
    }
    switch action {
    case .delete(let targets, let recursive, let force):
        return .delete(targets: targets + [outside], recursive: recursive, force: force)
    case .move(let sources, let destination):
        return .move(sources: sources + [outside], destination: destination)
    case .overwrite(let targets):
        return .overwrite(targets: targets + [outside])
    case .chmod(let targets, let mode, let recursive):
        return .chmod(targets: targets + [outside], mode: mode, recursive: recursive)
    case .create(let targets):
        return .create(targets: targets + [outside])
    case .read(let targets):
        return .read(targets: targets + [outside])
    }
}

/// A dynamic path in a mutation position may expand to anywhere, so it
/// classifies outside the repository and the existing outside-mutation
/// rules fail closed in every world. Static paths return nil and classify
/// normally, so static-outside evidence survives beside dynamic operands
/// (`cp $f /tmp/eve`). Reads never reach here (skipped above). Heads
/// additionally treat glob/brace spellings as dynamic (a verb the parser
/// cannot name); operands never do (`touch *.txt` classifies normally).
private func dynamicOutsideTarget(
    _ apparent: String,
    context: FilesystemAnalysisContext,
    head: Bool = false
) -> FilesystemTarget? {
    guard isDynamicToken(apparent) || (head && isGlobBraceHead(apparent)) else { return nil }
    return FilesystemTarget(
        apparent: apparent,
        canonical: lexicalFilesystemPath(
            apparent,
            workingDirectory: context.workingDirectory,
            homeDirectory: context.homeDirectory
        ),
        scope: .outsideRepository,
        kind: .unknown,
        resolution: .lexical
    )
}
