import RVDomain

/// Pure filesystem classifier. Unknown or unsupported syntax is `.unknown`.
public func analyzeFilesystem(
    _ command: ShellCommand,
    context: FilesystemAnalysisContext = .empty
) -> SemanticAnalysis {
    let view = Normalize.matchingView(of: command.rawValue).rawValue
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
    let view = Normalize.matchingView(of: command.rawValue).rawValue
    if view.isEmpty { return [] }
    if splitSegments(view).count > 1 { return [] }
    let tokens = tokenizeCommand(view).map(\.decoded)
    if tokens.contains(where: isDynamicToken) { return [] }
    return parseFilesystemCommand(tokens)?.paths ?? []
}

private struct ParsedFilesystemCommand {
    var operation: FilesystemOperation
    var paths: [String]
    var recursive: Bool
    var force: Bool
    var mode: String?
}

private enum FilesystemOperation {
    case delete
    case move
    case overwrite
    case chmod
    case create
    case read
}

private func parseFilesystemCommand(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let first = tokens.first else { return nil }
    let head = basename(first).lowercased()
    switch head {
    case "rm":
        return parseRm(Array(tokens.dropFirst()))
    case "unlink":
        return parseUnlink(Array(tokens.dropFirst()))
    case "rmdir":
        return parseRmdir(Array(tokens.dropFirst()))
    case "mv":
        return parseMv(Array(tokens.dropFirst()))
    case "chmod":
        return parseChmod(Array(tokens.dropFirst()))
    case "truncate":
        return parseTruncate(Array(tokens.dropFirst()))
    case "shred":
        return parseShred(Array(tokens.dropFirst()))
    case "touch":
        return parseTouch(Array(tokens.dropFirst()))
    case "mkdir":
        return parseMkdir(Array(tokens.dropFirst()))
    case "cat":
        if let redirect = parseRedirectOnly(tokens), redirect.paths.isEmpty == false {
            return redirect
        }
        return parseCat(Array(tokens.dropFirst()))
    default:
        return parseRedirectOnly(tokens)
    }
}

private func parseRm(_ args: [String]) -> ParsedFilesystemCommand? {
    var recursive = false
    var force = false
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--recursive" || token == "--dir" || token == "--directory" {
            recursive = true
            index += 1
            continue
        }
        if token == "--force" {
            force = true
            index += 1
            continue
        }
        if rmSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "r", "R", "d":
                    recursive = true
                case "f":
                    force = true
                case "v", "i", "I":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: recursive,
        force: force,
        mode: nil
    )
}

private let rmSkipLong: Set<String> = [
    "--verbose", "--interactive", "--one-file-system",
    "--preserve-root", "--no-preserve-root",
]

private func parseUnlink(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    for token in args {
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if token == "--help" || token == "--version" {
            return nil
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    guard paths.count == 1 else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private func parseRmdir(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if rmdirSkip.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "p", "v":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let rmdirSkip: Set<String> = [
    "--parents", "--verbose", "--ignore-fail-on-non-empty",
]

private func parseMv(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if mvSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f", "i", "n", "v", "u":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    guard paths.count >= 2 else { return nil }
    return ParsedFilesystemCommand(
        operation: .move,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let mvSkipLong: Set<String> = [
    "--force", "--interactive", "--no-clobber", "--verbose", "--update",
]

private func parseChmod(_ args: [String]) -> ParsedFilesystemCommand? {
    var recursive = false
    var mode: String?
    var paths: [String] = []
    var seenDash = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if seenDash {
            if mode == nil {
                guard isChmodMode(token) else { return nil }
                mode = token
            } else {
                paths.append(token)
            }
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "--recursive" {
            recursive = true
            index += 1
            continue
        }
        if chmodSkipLong.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "R":
                    recursive = true
                case "f", "v", "c", "h":
                    continue
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        if mode == nil {
            guard isChmodMode(token) else { return nil }
            mode = token
        } else {
            paths.append(token)
        }
        index += 1
    }
    guard let mode, paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .chmod,
        paths: paths,
        recursive: recursive,
        force: false,
        mode: mode
    )
}

private let chmodSkipLong: Set<String> = [
    "--silent", "--quiet", "--verbose", "--changes", "--no-dereference",
]

private func isChmodMode(_ token: String) -> Bool {
    if token.allSatisfy({ $0 >= "0" && $0 <= "7" }), (3...4).contains(token.count) {
        return true
    }
    return token.contains(where: { $0 == "+" || $0 == "-" || $0 == "=" })
}

private func parseTruncate(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectSize = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if expectSize {
            expectSize = false
            index += 1
            continue
        }
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if token == "-s" || token == "--size" {
            expectSize = true
            index += 1
            continue
        }
        if token.hasPrefix("--size=") {
            index += 1
            continue
        }
        if truncateSkip.contains(token) {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "c", "o", "r":
                    continue
                case "s":
                    expectSize = true
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    if expectSize { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let truncateSkip: Set<String> = [
    "--no-create", "--io-blocks", "--verbose",
]

private func parseShred(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectValue = false
    var index = 0
    while index < args.count {
        let token = args[index]
        if expectValue {
            expectValue = false
            index += 1
            continue
        }
        if seenDash {
            paths.append(token)
            index += 1
            continue
        }
        if token == "--" {
            seenDash = true
            index += 1
            continue
        }
        if shredValueLong.contains(token) {
            expectValue = true
            index += 1
            continue
        }
        if shredSkipLong.contains(token) || token.hasPrefix("--remove=")
            || token.hasPrefix("--iterations=") || token.hasPrefix("--size=")
        {
            index += 1
            continue
        }
        if let letters = clusteredShorts(token) {
            for letter in letters {
                switch letter {
                case "f", "u", "z", "v", "x":
                    continue
                case "n", "s":
                    expectValue = true
                default:
                    return nil
                }
            }
            index += 1
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
        index += 1
    }
    if expectValue { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .delete,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let shredSkipLong: Set<String> = [
    "--force", "--remove", "--zero", "--verbose", "--exact",
]
private let shredValueLong: Set<String> = [
    "--iterations", "--size",
]

private func parseTouch(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectValue = false
    for token in args {
        if expectValue {
            expectValue = false
            continue
        }
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if token == "-t" || token == "-d" || token == "--date" || token == "--time" {
            expectValue = true
            continue
        }
        if token.hasPrefix("--date=") || token.hasPrefix("--time=") {
            continue
        }
        if touchSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "a", "c", "f", "h", "m":
                    continue
                case "t", "d":
                    expectValue = true
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    if expectValue { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let touchSkipLong: Set<String> = [
    "--no-create", "--no-dereference", "--help", "--version",
]

private func parseMkdir(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    var expectMode = false
    for token in args {
        if expectMode {
            expectMode = false
            continue
        }
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if token == "-m" || token == "--mode" {
            expectMode = true
            continue
        }
        if token.hasPrefix("--mode=") {
            continue
        }
        if mkdirSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "p", "v":
                    continue
                case "m":
                    expectMode = true
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    if expectMode { return nil }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .create,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let mkdirSkipLong: Set<String> = [
    "--parents", "--verbose", "--help", "--version",
]

private func parseCat(_ args: [String]) -> ParsedFilesystemCommand? {
    var paths: [String] = []
    var seenDash = false
    for token in args {
        if seenDash {
            paths.append(token)
            continue
        }
        if token == "--" {
            seenDash = true
            continue
        }
        if catSkipLong.contains(token) {
            continue
        }
        if let letters = clusteredShorts(token) {
            var valid = true
            for letter in letters {
                switch letter {
                case "A", "b", "E", "e", "n", "s", "T", "t", "u", "v":
                    continue
                default:
                    valid = false
                }
            }
            if valid == false { return nil }
            continue
        }
        if token.hasPrefix("-") { return nil }
        paths.append(token)
    }
    guard paths.isEmpty == false else { return nil }
    return ParsedFilesystemCommand(
        operation: .read,
        paths: paths,
        recursive: false,
        force: false,
        mode: nil
    )
}

private let catSkipLong: Set<String> = [
    "--show-all", "--number-nonblank", "--show-ends", "--number",
    "--squeeze-blank", "--show-tabs", "--show-nonprinting", "--help", "--version",
]

private func parseRedirectOnly(_ tokens: [String]) -> ParsedFilesystemCommand? {
    guard let targets = redirectTargets(tokens), targets.isEmpty == false else {
        return nil
    }
    return ParsedFilesystemCommand(
        operation: .overwrite,
        paths: targets,
        recursive: false,
        force: false,
        mode: nil
    )
}

private func redirectTargets(_ tokens: [String]) -> [String]? {
    var targets: [String] = []
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        if isFdDup(token) {
            index += 1
            continue
        }
        if isRedirectOperator(token) {
            guard index + 1 < tokens.count else { return nil }
            let dest = tokens[index + 1]
            if dest.hasPrefix("&") {
                index += 2
                continue
            }
            if isDynamicToken(dest) { return nil }
            targets.append(dest)
            index += 2
            continue
        }
        if let attached = attachedRedirectTarget(token) {
            if isDynamicToken(attached) { return nil }
            targets.append(attached)
        }
        index += 1
    }
    return targets
}

private func isFdDup(_ token: String) -> Bool {
    token == "2>&1" || token == "1>&2" || token == ">&1" || token == ">&2"
}

private func isRedirectOperator(_ token: String) -> Bool {
    token == ">" || token == ">|" || token == ">>" || token == "&>" || token == "1>"
        || token == "2>"
}

private func attachedRedirectTarget(_ token: String) -> String? {
    if token.hasPrefix(">>"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix(">|"), token.count > 2 {
        return String(token.dropFirst(2))
    }
    if token.hasPrefix("&>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix("1>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix("2>"), token.count > 2 {
        let rest = String(token.dropFirst(2))
        return rest.hasPrefix("&") ? nil : rest
    }
    if token.hasPrefix(">"), token.count > 1, token.hasPrefix(">&") == false {
        return String(token.dropFirst())
    }
    return nil
}

func classifyFilesystemTarget(
    _ apparent: String,
    context: FilesystemAnalysisContext
) -> FilesystemTarget {
    if let fact = context.fact(for: apparent) {
        return classifiedTarget(
            apparent: apparent,
            canonical: fact.canonical,
            followedSymlink: fact.followedSymlink,
            resolution: fact.resolution,
            context: context
        )
    }
    let canonical = lexicalFilesystemPath(
        apparent,
        workingDirectory: context.workingDirectory?.rawValue,
        homeDirectory: context.homeDirectory
    )
    return classifiedTarget(
        apparent: apparent,
        canonical: canonical,
        followedSymlink: false,
        resolution: .lexical,
        context: context
    )
}

/// Uncertain resolution never claims inside/outside. Fail-closed as unknown.
func filesystemScopeForResolution(
    _ resolution: FilesystemResolution,
    canonical: String,
    repositoryRoot: RepositoryRoot?,
    catalog: SecretPathCatalog
) -> FilesystemScope {
    if resolution == .uncertain {
        return .unknown
    }
    return classifyFilesystemScope(
        canonical: canonical,
        repositoryRoot: repositoryRoot,
        catalog: catalog
    )
}

public func lexicalFilesystemPath(
    _ apparent: String,
    workingDirectory: String?,
    homeDirectory: String?
) -> String {
    let expanded = expandHomeAlias(apparent, homeDirectory: homeDirectory)
    let absolute: String
    if expanded.hasPrefix("/") {
        absolute = expanded
    } else if let workingDirectory {
        absolute = joinFilesystemPath(workingDirectory, expanded)
    } else {
        absolute = expanded
    }
    return collapseFilesystemPath(absolute)
}

func classifyFilesystemScope(
    canonical: String,
    repositoryRoot: RepositoryRoot?,
    catalog: SecretPathCatalog
) -> FilesystemScope {
    if catalog.firstMatch(of: canonical) != nil {
        return .protectedPath
    }
    guard let repositoryRoot else { return .unknown }
    if isInsideRepository(canonical, root: repositoryRoot.rawValue) {
        return .insideRepository
    }
    return .outsideRepository
}

func classifyFilesystemKind(_ canonical: String) -> FilesystemResourceKind {
    let parts = canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if parts.contains(where: { generatedPathNames.contains($0) }) {
        return .generatedOutput
    }
    if let last = parts.last {
        if let dot = last.lastIndex(of: "."), dot != last.startIndex {
            let ext = String(last[dot...]).lowercased()
            if sourceExtensions.contains(ext) {
                return .sourceCode
            }
        }
    }
    if parts.contains(where: { sourceDirectoryNames.contains($0) }) {
        return .sourceCode
    }
    return .unknown
}

private func classifiedTarget(
    apparent: String,
    canonical: String,
    followedSymlink: Bool,
    resolution: FilesystemResolution,
    context: FilesystemAnalysisContext
) -> FilesystemTarget {
    FilesystemTarget(
        apparent: apparent,
        canonical: canonical,
        scope: filesystemScopeForResolution(
            resolution,
            canonical: canonical,
            repositoryRoot: context.repositoryRoot,
            catalog: context.catalog
        ),
        kind: classifyFilesystemKind(canonical),
        followedSymlink: followedSymlink,
        resolution: resolution,
        protectedMatch: protectedMatch(
            canonical: canonical,
            resolution: resolution,
            catalog: context.catalog
        )
    )
}

private func protectedMatch(
    canonical: String,
    resolution: FilesystemResolution,
    catalog: SecretPathCatalog
) -> SecretPathMatch? {
    guard resolution != .uncertain else { return nil }
    return catalog.firstMatch(of: canonical).map(SecretPathMatch.init)
}

private func isHomeAliasPath(_ path: String) -> Bool {
    // Mirrors RVDomain.isHomeAliasPath — keep private; see SecretPathMatching.swift
    // for the single matcher used by catalog/policy.
    path == "~" || path.hasPrefix("~/")
        || path == "$HOME" || path.hasPrefix("$HOME/")
        || path == "${HOME}" || path.hasPrefix("${HOME}/")
}

private func expandHomeAlias(_ path: String, homeDirectory: String?) -> String {
    guard let homeDirectory, isHomeAliasPath(path) else {
        return path
    }
    if path == "~" || path == "$HOME" || path == "${HOME}" {
        return homeDirectory
    }
    if path.hasPrefix("~/") {
        return joinFilesystemPath(homeDirectory, String(path.dropFirst(2)))
    }
    if path.hasPrefix("$HOME/") {
        return joinFilesystemPath(homeDirectory, String(path.dropFirst(6)))
    }
    return joinFilesystemPath(homeDirectory, String(path.dropFirst(8)))
}

private func joinFilesystemPath(_ left: String, _ right: String) -> String {
    if right.hasPrefix("/") { return right }
    if left == "/" { return "/" + right }
    if left.hasSuffix("/") { return left + right }
    return left + "/" + right
}

private func collapseFilesystemPath(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    var parts: [String] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
        if component == "." { continue }
        if component == ".." {
            if parts.isEmpty == false {
                parts.removeLast()
            }
            continue
        }
        parts.append(String(component))
    }
    if absolute {
        return "/" + parts.joined(separator: "/")
    }
    return parts.joined(separator: "/")
}

private func isInsideRepository(_ canonical: String, root: String) -> Bool {
    let normalizedRoot = collapseFilesystemPath(root)
    if canonical == normalizedRoot { return true }
    let prefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
    return canonical.hasPrefix(prefix)
}

private let generatedPathNames: Set<String> = [
    ".build", "build", "dist", "DerivedData", "node_modules", "target",
    ".swiftpm", "Pods", "__pycache__", ".gradle", "out", ".next", "coverage",
]

private let sourceDirectoryNames: Set<String> = [
    "Sources", "src", "lib", "app",
]

private let sourceExtensions: Set<String> = [
    ".swift", ".c", ".h", ".hh", ".hpp", ".m", ".mm", ".cc", ".cpp", ".cxx",
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".go", ".rs",
    ".java", ".kt", ".kts", ".rb", ".sh", ".zsh", ".bash",
]

private func clusteredShorts(_ token: String) -> [Character]? {
    guard token.hasPrefix("-"), token.hasPrefix("--") == false, token.count > 1 else {
        return nil
    }
    if token.contains("=") { return nil }
    return Array(token.dropFirst())
}

private func isDynamicToken(_ token: String) -> Bool {
    // Home aliases contain `$` but are expanded lexically, not dynamically.
    // Exempt them so `echo hi > $HOME/.ssh/config` is not treated as unknown.
    if isHomeAliasPath(token) { return false }
    return token.contains("$") || token.contains("`")
}
