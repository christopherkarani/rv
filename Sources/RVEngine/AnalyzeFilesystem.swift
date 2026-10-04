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
        return .unknown
    }
    guard let action = filesystemAction(parsed: parsed, context: context) else {
        return .unknown
    }
    return .filesystem(action)
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
    context: FilesystemAnalysisContext
) -> [FilesystemAction] {
    // Straight-line `cd`/`pushd`/`popd` tracking: each segment parses
    // against the pre-segment cwd, then updates the tracker for later
    // segments, so `cd /tmp && touch evil` resolves `evil` outside.
    var tracker = DirectoryTracker(
        working: context.workingDirectory?.rawValue,
        home: context.homeDirectory?.rawValue
    )
    var actions: [FilesystemAction] = []
    let segments = splitSegments(view).flatMap {
        splitSegments(ShellPipeline.stripLeadingAssignmentPrefixes($0))
    }
    for segment in segments {
        let tokens = tokenizeFilesystemWords(segment)
        var segmentContext = context
        segmentContext.workingDirectory = tracker.working.flatMap(WorkingDirectory.init(validating:))
        if let parsed = parseFilesystemCommand(tokens),
            let action = filesystemAction(parsed: parsed, context: segmentContext)
        {
            actions.append(action)
        } else if let head = tokens.first, isDynamicToken(head),
            let outside = dynamicOutsideTarget(head, context: segmentContext)
        {
            // C-F7: a dynamic argv0 (`$(...)`, backticks, `$VAR`) hides the
            // verb itself, so no parser can claim the segment. The operation
            // cannot be established — fail closed as an outside overwrite
            // (Step 8B §10) rather than skipping into unknown → allow.
            // Home-alias heads (`$HOME/bin/tool`) expand lexically and stay
            // unclaimed via isDynamicToken.
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

/// A dynamic path in a mutation position may expand to anywhere, so it
/// classifies outside the repository and the existing outside-mutation
/// rules fail closed in every world. Static paths return nil and classify
/// normally, so static-outside evidence survives beside dynamic operands
/// (`cp $f /tmp/eve`). Reads never reach here (skipped above).
private func dynamicOutsideTarget(
    _ apparent: String,
    context: FilesystemAnalysisContext
) -> FilesystemTarget? {
    guard isDynamicToken(apparent) else { return nil }
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
