import RVDomain

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
        workingDirectory: context.workingDirectory,
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
    workingDirectory: WorkingDirectory?,
    homeDirectory: HomePath?
) -> String {
    let expanded = expandHomeAlias(apparent, homeDirectory: homeDirectory)
    let absolute: String
    if expanded.hasPrefix("/") {
        absolute = expanded
    } else if let workingDirectory {
        absolute = joinFilesystemPath(workingDirectory.rawValue, expanded)
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
    if let rule = catalog.firstMatch(of: canonical) {
        return .protectedPath(SecretPathMatch(rule))
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
        resolution: resolution
    )
}

private func expandHomeAlias(_ path: String, homeDirectory: HomePath?) -> String {
    guard let homeDirectory, isHomeAliasPath(path) else {
        return path
    }
    let home = homeDirectory.rawValue
    if path == "~" || path == "$HOME" || path == "${HOME}" {
        return home
    }
    if path.hasPrefix("~/") {
        return joinFilesystemPath(home, String(path.dropFirst(2)))
    }
    if path.hasPrefix("$HOME/") {
        return joinFilesystemPath(home, String(path.dropFirst(6)))
    }
    return joinFilesystemPath(home, String(path.dropFirst(8)))
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
