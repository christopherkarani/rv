/// Review input with credentials removed. Deliberately NOT a `ProposedAction`:
/// redaction can delete the very text a deny rule matches, so hard policy must
/// never be evaluated on this type. `ActionPolicyEngine` accepts only
/// `ProposedAction`, which makes that mistake a compile error.
///
/// The shell and file arms expose no `ActionFingerprint`. Their redacted
/// fingerprint is display text (`fingerprintText`) and cannot be used for
/// approval lookup. The http and secretRequest arms keep the real types
/// because redaction leaves them credential-free and policy-equivalent: HTTP
/// only drops the query, whose SHA-256 token already sits in the fingerprint,
/// and a secret request is returned unchanged.
public enum RedactedAction: Sendable, Equatable, Codable {
    case shell(RedactedShell)
    case file(RedactedFile)
    case http(HTTPAction)
    case secretRequest(SecretRequestAction)

    public var scope: ActionScope {
        switch self {
        case .shell(let shell):
            return shell.scope
        case .file(let file):
            return file.scope
        case .http(let http):
            return http.scope
        case .secretRequest(let request):
            return request.scope
        }
    }

    public var supportingCommand: ShellCommand? {
        switch self {
        case .shell(let shell):
            return shell.supportingCommand
        case .file, .http, .secretRequest:
            return nil
        }
    }

    /// Wire shape identical to the sanitized `ProposedAction`.
    private var wire: ProposedAction {
        switch self {
        case .shell(let shell):
            return .shell(shell.sanitized)
        case .file(let file):
            return .file(file.sanitized)
        case .http(let http):
            return .http(http)
        case .secretRequest(let request):
            return .secretRequest(request)
        }
    }

    public init(from decoder: Decoder) throws {
        self = ReviewSanitizer.sanitize(try ProposedAction(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try wire.encode(to: encoder)
    }
}

/// Redacted shell action. Wraps the sanitized value privately so its
/// `ActionFingerprint` is unreachable.
public struct RedactedShell: Sendable, Equatable, Encodable {
    fileprivate let sanitized: ShellAction

    fileprivate init(_ sanitized: ShellAction) {
        self.sanitized = sanitized
    }

    /// Redacted display text. Not a lookup key.
    public var fingerprintText: String { sanitized.fingerprint.rawValue }
    public var effects: ActionEffects { sanitized.effects }
    public var resources: ResourceScope { sanitized.resources }
    public var scope: ActionScope { sanitized.scope }
    public var supportingCommand: ShellCommand? { sanitized.supportingCommand }
    // Internal (tests only): a public `GitAction`/`FilesystemAction` would
    // rebuild a `ProposedAction` via `proposedAction(command:workingDirectory:)`.
    var gitAction: GitAction? { sanitized.gitAction }
    var filesystemAction: FilesystemAction? { sanitized.filesystemAction }

    public func encode(to encoder: Encoder) throws {
        try sanitized.encode(to: encoder)
    }
}

/// Redacted file-tool action. See `RedactedShell`.
public struct RedactedFile: Sendable, Equatable, Encodable {
    fileprivate let sanitized: FileAction

    fileprivate init(_ sanitized: FileAction) {
        self.sanitized = sanitized
    }

    /// Redacted display text. Not a lookup key.
    public var fingerprintText: String { sanitized.fingerprint.rawValue }
    public var file: FileToolAction { sanitized.file }
    public var effects: ActionEffects { sanitized.effects }
    public var resources: ResourceScope { sanitized.resources }
    public var scope: ActionScope { sanitized.scope }

    public func encode(to encoder: Encoder) throws {
        try sanitized.encode(to: encoder)
    }
}

/// Drops raw credentials from review input. Raw shell strings stay supporting
/// evidence and are redacted when they carry secret-shaped text.
public enum ReviewSanitizer: Sendable {
    public static let redactedPlaceholder = "[redacted]"

    public static func sanitize(_ action: ProposedAction) -> RedactedAction {
        switch action {
        case .shell(let shell):
            return .shell(sanitize(shell))
        case .file(let file):
            return .file(sanitize(file))
        case .http(let http):
            return .http(http.redactingQuery())
        case .secretRequest(let request):
            // Built without the query or any placeholder.
            return .secretRequest(request)
        }
    }

    public static func sanitize(_ shell: ShellAction) -> RedactedShell {
        RedactedShell(redact(shell))
    }

    public static func sanitize(_ file: FileAction) -> RedactedFile {
        RedactedFile(redact(file))
    }

    private static func redact(_ shell: ShellAction) -> ShellAction {
        let fingerprint = ActionFingerprint(
            rawValue: redactCredentials(in: shell.fingerprint.rawValue)
        )
        let scope = ActionScope(
            workingDirectory: shell.scope.workingDirectory.flatMap { directory in
                WorkingDirectory(rawValue: redactCredentials(in: directory.rawValue))
            }
        )
        let supportingCommand = shell.supportingCommand.map { command in
            ShellCommand(rawValue: redactCredentials(in: command.rawValue))
        }
        switch shell {
        case .analyzed(let analyzed):
            return ShellAction.analyzed(
                AnalyzedShell(
                    fingerprint: fingerprint,
                    scope: scope,
                    supportingCommand: supportingCommand,
                    analysis: sanitize(analyzed.analysis)
                )
            )
        case .effectOnly(let effect):
            return ShellAction.effectOnly(
                EffectShell(
                    fingerprint: fingerprint,
                    effects: effect.effects,
                    resources: ActionResources(
                        remoteName: sanitizeField(effect.resources.remoteName),
                        branchName: sanitizeField(effect.resources.branchName),
                        path: sanitizeField(effect.resources.path),
                        filesystemScope: effect.resources.filesystemScope,
                        resourceKind: effect.resources.resourceKind
                    ),
                    scope: scope,
                    supportingCommand: supportingCommand
                )
            )
        }
    }

    private static func redact(_ file: FileAction) -> FileAction {
        FileAction(
            fingerprint: ActionFingerprint(
                rawValue: redactCredentials(in: file.fingerprint.rawValue)
            ),
            file: FileToolAction(
                kind: file.file.kind,
                path: FileToolPath(rawValue: sanitizeField(file.file.path.rawValue) ?? file.file.path.rawValue)
            ),
            scope: ActionScope(
                workingDirectory: file.scope.workingDirectory.flatMap { directory in
                    WorkingDirectory(rawValue: redactCredentials(in: directory.rawValue))
                }
            )
        )
    }

    public static func sanitize(_ context: ReviewContext) -> ReviewContext {
        ReviewContext(
            repository: RepositoryReviewContext(
                name: sanitizeField(context.repository.name),
                currentBranch: sanitizeField(context.repository.currentBranch)
            ),
            environment: EnvironmentReviewContext(
                labels: context.environment.labels.compactMap { label in
                    guard looksLikeSecretKey(label) == false else { return nil }
                    let cleaned = redactCredentials(in: label)
                    return looksLikeSecretValue(cleaned) ? nil : cleaned
                },
                isCI: context.environment.isCI
            ),
            metadata: sanitize(metadata: context.metadata)
        )
    }

    public static func redactCredentials(in text: String) -> String {
        if looksLikePEM(text) {
            return redactedPlaceholder
        }
        var previousLower = ""
        return mapWhitespaceTokens(in: text) { token in
            let redacted: String
            if previousLower == "bearer" {
                redacted = redactedPlaceholder
            } else {
                redacted = redactAssignmentOrPrefix(token)
            }
            previousLower = token.lowercased()
            return redacted
        }
    }

    private static func sanitize(metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            if looksLikeSecretKey(key) { continue }
            if looksLikeSecretValue(value) { continue }
            result[key] = redactCredentials(in: value)
        }
        return result
    }

    private static func sanitize(_ analysis: SemanticAction) -> SemanticAction {
        switch analysis {
        case .git(let git):
            return .git(sanitize(git))
        case .filesystem(let filesystem):
            return .filesystem(sanitize(filesystem))
        }
    }

    private static func sanitize(_ action: GitAction) -> GitAction {
        switch action {
        case .createBranch(let name, let startPoint, let force):
            return .createBranch(
                name: sanitizeText(name),
                startPoint: startPoint.map(sanitizeText),
                force: force
            )
        case .switchBranch(let name, let force):
            return .switchBranch(name: sanitizeText(name), force: force)
        case .discardWorktree(let pathspecs, let source):
            return .discardWorktree(
                pathspecs: pathspecs.map(sanitizeText),
                source: source.map(sanitizeText)
            )
        case .restore(let pathspecs, let destination, let source):
            return .restore(
                pathspecs: pathspecs.map(sanitizeText),
                destination: destination,
                source: source.map(sanitizeText)
            )
        case .reset(let mode, let target):
            return .reset(mode: mode, target: target.map(sanitizeText))
        case .clean:
            return action
        case .push(let remote, let refspec, let force):
            return .push(
                remote: remote.map(sanitizeText),
                refspec: refspec.map(sanitizeText),
                force: force
            )
        case .pushUnparsed(let args):
            return .pushUnparsed(args: args.map(sanitizeText))
        case .deleteRemoteRef(let remote, let refspec):
            return .deleteRemoteRef(
                remote: remote.map(sanitizeText),
                refspec: refspec.map(sanitizeText)
            )
        case .deleteBranch(let name, let force):
            return .deleteBranch(name: sanitizeText(name), force: force)
        case .deleteTag(let name, let remote):
            return .deleteTag(name: sanitizeText(name), remote: remote.map(sanitizeText))
        case .stash:
            return action
        case .rebase(let verb, let onto):
            return .rebase(verb: verb, onto: onto.map(sanitizeText))
        }
    }

    private static func sanitize(_ action: FilesystemAction) -> FilesystemAction {
        switch action {
        case .delete(let targets, let recursive, let force):
            return .delete(targets: targets.map(sanitize), recursive: recursive, force: force)
        case .move(let sources, let destination):
            return .move(sources: sources.map(sanitize), destination: sanitize(destination))
        case .overwrite(let targets):
            return .overwrite(targets: targets.map(sanitize))
        case .chmod(let targets, let mode, let recursive):
            return .chmod(
                targets: targets.map(sanitize),
                mode: mode.map(sanitizeText),
                recursive: recursive
            )
        case .create(let targets):
            return .create(targets: targets.map(sanitize))
        case .read(let targets):
            return .read(targets: targets.map(sanitize))
        }
    }

    private static func sanitize(_ target: FilesystemTarget) -> FilesystemTarget {
        FilesystemTarget(
            apparent: sanitizeText(target.apparent),
            canonical: sanitizeText(target.canonical),
            scope: target.scope,
            kind: target.kind,
            followedSymlink: target.followedSymlink,
            resolution: target.resolution
        )
    }

    private static func sanitizeField(_ value: String?) -> String? {
        value.map(sanitizeText)
    }

    private static func sanitizeText(_ value: String) -> String {
        if looksLikeSecretValue(value) {
            return redactedPlaceholder
        }
        return redactCredentials(in: value)
    }

    private static func redactAssignmentOrPrefix(_ token: String) -> String {
        if let equals = token.firstIndex(of: "=") {
            let key = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            // Keep a non-secret key when only the value is credential-shaped.
            // If the key itself carries a prefix/PAT, drop the whole token.
            if looksLikeSecretValue(key) == false,
               looksLikeSecretKey(key) || looksLikeSecretValue(value)
            {
                return "\(key)=\(redactedPlaceholder)"
            }
        }
        if containsSecretPrefix(token) {
            return redactedPlaceholder
        }
        return token
    }

    private static func mapWhitespaceTokens(in text: String, transform: (String) -> String) -> String {
        var output = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                if token.isEmpty == false {
                    output.append(transform(token))
                    token = ""
                }
                output.append(character)
            } else {
                token.append(character)
            }
        }
        if token.isEmpty == false {
            output.append(transform(token))
        }
        return output
    }

    private static func looksLikeSecretKey(_ raw: String) -> Bool {
        let folded = String(raw.lowercased().map { character -> Character in
            if character == "-" || character == "." {
                return "_"
            }
            return character
        })
        for fragment in secretKeyFragments where folded.contains(fragment) {
            return true
        }
        return false
    }

    private static func looksLikeSecretValue(_ value: String) -> Bool {
        looksLikePEM(value) || containsSecretPrefix(value)
    }

    private static func looksLikePEM(_ text: String) -> Bool {
        text.contains("PRIVATE KEY") || text.contains("BEGIN OPENSSH")
    }

    /// Secret prefixes may sit after `://`, `@`, `:`, `=`, or `/` rather than at
    /// the whitespace-token start (URL-embedded PATs, `FOO=ghp_…`).
    private static func containsSecretPrefix(_ token: String) -> Bool {
        token.split { character in
            character == ":" || character == "=" || character == "@" || character == "/"
        }
        .contains { segment in
            secretValuePrefixes.contains { segment.hasPrefix($0) }
        }
    }

    private static let secretKeyFragments = [
        "password",
        "passwd",
        "secret",
        "token",
        "authorization",
        "credential",
        "api_key",
        "apikey",
        "private_key",
        "privatekey",
        "access_key",
        "accesskey",
    ]

    private static let secretValuePrefixes = [
        "ghp_",
        "github_pat_",
        "sk-",
        "AKIA",
    ]
}
