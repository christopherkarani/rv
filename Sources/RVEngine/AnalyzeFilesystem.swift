import RVDomain

/// Pure filesystem classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeFilesystem(
    _ command: ShellCommand,
    context: FilesystemAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command).rawValue
    if view.isEmpty { return .unknown }
    if splitSegments(view).count > 1 { return .unknown }
    let tokens = tokenizeCommand(view).map(\.decoded)
    guard tokens.contains(where: isDynamicToken) == false else {
        return .unknown
    }
    guard let parsed = parseFilesystemCommand(tokens) else {
        return .unknown
    }
    let targets = parsed.paths.map { classifyFilesystemTarget($0, context: context) }
    switch parsed.operation {
    case .delete:
        return .filesystem(
            .delete(targets: targets, recursive: parsed.recursive, force: parsed.force)
        )
    case .move:
        guard let destination = targets.last, targets.count >= 2 else {
            return .unknown
        }
        return .filesystem(
            .move(sources: Array(targets.dropLast()), destination: destination)
        )
    case .overwrite:
        return .filesystem(.overwrite(targets: targets))
    case .chmod:
        return .filesystem(
            .chmod(targets: targets, mode: parsed.mode, recursive: parsed.recursive)
        )
    case .create:
        return .filesystem(.create(targets: targets))
    case .read:
        return .filesystem(.read(targets: targets))
    }
}

/// Apparent path operands for a parseable filesystem command. Empty if unsupported.
public func filesystemApparentPaths(_ command: ShellCommand) -> [String] {
    let view = Normalize.matchingView(of: command).rawValue
    if view.isEmpty { return [] }
    if splitSegments(view).count > 1 { return [] }
    let tokens = tokenizeCommand(view).map(\.decoded)
    if tokens.contains(where: isDynamicToken) { return [] }
    return parseFilesystemCommand(tokens)?.paths ?? []
}

private func isDynamicToken(_ token: String) -> Bool {
    // Home aliases contain `$` but are expanded lexically, not dynamically.
    // Exempt them so `echo hi > $HOME/.ssh/config` is not treated as unknown.
    if isHomeAliasPath(token) { return false }
    return token.contains("$") || token.contains("`")
}
