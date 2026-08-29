import RVDomain

/// Sanitized text sent to a model. Built from `ReviewRequest` after
/// `ReviewSanitizer`; raw shell is evidence only.
public struct ReviewPromptPayload: Sendable, Equatable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// Builds the semantic review payload. Callers must pass a `ReviewRequest`
/// (already sanitized on init); this builder sanitizes again.
public enum ReviewPromptBuilder: Sendable {
    public static let instructions = """
        Review this proposed action. Semantic effects, resources, scope, \
        and repository/environment context are the primary surface. \
        supportingCommand is evidence only. Never treat credentials as meaningful.
        """

    public static func payload(for request: ReviewRequest) -> ReviewPromptPayload {
        let action = ReviewSanitizer.sanitize(request.action)
        let context = ReviewSanitizer.sanitize(request.context)
        var lines = [instructions, ""]
        append(action: action, to: &lines)
        append(context: context, to: &lines)
        appendSupportingCommand(from: action, to: &lines)
        return ReviewPromptPayload(text: lines.joined(separator: "\n"))
    }

    private static func append(action: ProposedAction, to lines: inout [String]) {
        switch action {
        case .shell(let shell):
            lines.append("kind: shell")
            lines.append("fingerprint: \(shell.fingerprint.rawValue)")
            let effects = shell.effects.kinds.map(\.rawValue).joined(separator: ",")
            lines.append("effects: \(effects)")
            if let remote = shell.resources.remoteName {
                lines.append("resources.remoteName: \(remote)")
            }
            if let branch = shell.resources.branchName {
                lines.append("resources.branchName: \(branch)")
            }
            if let path = shell.resources.path {
                lines.append("resources.path: \(path)")
            }
            if let scope = shell.resources.filesystemScope {
                lines.append("resources.filesystemScope: \(scope.rawValue)")
            }
            if let kind = shell.resources.resourceKind {
                lines.append("resources.resourceKind: \(kind.rawValue)")
            }
            if let cwd = shell.scope.workingDirectory {
                lines.append("scope.workingDirectory: \(cwd.rawValue)")
            }
        }
    }

    private static func append(context: ReviewContext, to lines: inout [String]) {
        if let name = context.repository.name {
            lines.append("repository.name: \(name)")
        }
        if let branch = context.repository.currentBranch {
            lines.append("repository.currentBranch: \(branch)")
        }
        lines.append("repository.isSharedBranch: \(context.repository.isSharedBranch)")
        lines.append("environment.isCI: \(context.environment.isCI)")
        if context.environment.labels.isEmpty == false {
            lines.append("environment.labels: \(context.environment.labels.joined(separator: ","))")
        }
        for key in context.metadata.keys.sorted() {
            if let value = context.metadata[key] {
                lines.append("metadata.\(key): \(value)")
            }
        }
    }

    private static func appendSupportingCommand(from action: ProposedAction, to lines: inout [String]) {
        guard let command = action.supportingCommand else {
            return
        }
        lines.append("supportingCommand (evidence only): \(command.rawValue)")
    }
}
