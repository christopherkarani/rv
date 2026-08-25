/// Drops raw credentials from review input. Raw shell strings stay supporting
/// evidence and are redacted when they carry secret-shaped text.
public enum ReviewSanitizer: Sendable {
    public static let redactedPlaceholder = "[redacted]"

    public static func sanitize(_ action: ProposedAction) -> ProposedAction {
        switch action {
        case .shell(let shell):
            return .shell(sanitize(shell))
        }
    }

    public static func sanitize(_ shell: ShellAction) -> ShellAction {
        ShellAction(
            fingerprint: shell.fingerprint,
            effects: shell.effects,
            resources: ActionResources(
                remoteName: sanitizeField(shell.resources.remoteName),
                branchName: sanitizeField(shell.resources.branchName)
            ),
            scope: shell.scope,
            supportingCommand: shell.supportingCommand.map { command in
                ShellCommand(rawValue: redactCredentials(in: command.rawValue))
            }
        )
    }

    public static func sanitize(_ context: ReviewContext) -> ReviewContext {
        ReviewContext(
            repository: RepositoryReviewContext(
                name: sanitizeField(context.repository.name),
                currentBranch: sanitizeField(context.repository.currentBranch),
                isSharedBranch: context.repository.isSharedBranch
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

    private static func sanitizeField(_ value: String?) -> String? {
        guard let value else { return nil }
        if looksLikeSecretValue(value) {
            return redactedPlaceholder
        }
        return redactCredentials(in: value)
    }

    private static func redactAssignmentOrPrefix(_ token: String) -> String {
        if let equals = token.firstIndex(of: "=") {
            let key = String(token[..<equals])
            if looksLikeSecretKey(key) {
                return "\(key)=\(redactedPlaceholder)"
            }
        }
        if hasSecretPrefix(token) {
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
        looksLikePEM(value) || hasSecretPrefix(value)
    }

    private static func looksLikePEM(_ text: String) -> Bool {
        text.contains("PRIVATE KEY") || text.contains("BEGIN OPENSSH")
    }

    private static func hasSecretPrefix(_ token: String) -> Bool {
        for prefix in secretValuePrefixes where token.hasPrefix(prefix) {
            return true
        }
        return false
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
