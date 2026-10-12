// MARK: - Argument validation failures

/// Typed argument failures. Labels only; offending values never echo.
public enum MCPArgumentValidationError: Error, Hashable, Sendable, Equatable {
    /// The text is not a JSON object.
    case malformed
    /// The text exceeds the byte cap.
    case oversized
    /// The object holds too many keys.
    case tooManyKeys
    /// A key name is empty or overlong (label carries the index, not the key).
    case badKey(index: Int)
    /// A required key is missing or null (label carries the key name, which
    /// is schema vocabulary, never a value).
    case missingRequired(key: String)
}

// MARK: - Invoke-failure serving outcome

/// Serving-plane projection of one failed scoped invocation: every
/// `ScopedInvokeError` arm minus the opaque correlation payload (which
/// stays server-side on the cause log and audit row). Lives in RVDomain
/// so the total mapping below stays a pure function over domain types;
/// `ScopedInvokeError` itself stays in RVIsolation because its opaque arm
/// carries a file-store correlation id RVDomain cannot name.
public enum MCPInvokeFailure: Sendable, Equatable {
    /// No authenticated principal; nothing was touched.
    case principalRequired
    /// Policy resolved to block (label carries the matched rule id, if any).
    case policyDenied(matchedPolicyId: String?)
    /// The address is malformed or names no registered tool.
    case unknownTool
    /// The address names a connection outside the session's bound resource.
    case crossResource
    /// Arguments failed schema validation.
    case invalidArguments(MCPArgumentValidationError)
    /// The elicitation wait expired or was canceled.
    case elicitationTimeout
    /// No wait could park (cap full) or the backend failed.
    case elicitationUnavailable
    /// Post-approval secret resolution failed (typed broker cause).
    case credentialFailed(SecretsError)
    /// The audit append failed; the audited operation was denied.
    case auditFailed
    /// Opaque transport/tool failure. No payload: the correlation id never
    /// leaves the server.
    case opaque
}

/// What serving does with one invoke failure: answer an expected
/// `MCPToolError` value through the `fail` arm of `MCPToolResult`, or
/// answer the defect envelope.
public enum MCPInvokeFailureOutcome: Sendable, Equatable {
    /// Expected failure value for the `fail` arm.
    case expected(MCPToolError)
    /// Infra defect: serving answers `MCPEnvelopeResponse.internalError()`
    /// (-32603, fixed message). The correlation id stays server-side.
    case defect
}

extension MCPInvokeFailure {
    /// Maps one invoke failure onto its serving outcome. Total: every arm
    /// yields either an expected `MCPToolError` value or the defect
    /// envelope, so serving planes share one conversion instead of
    /// hand-mapping. Pure; labels only.
    ///
    /// - `path`: sandbox path of the attempted tool, for messages and
    ///   details. Labels only, like every other message input here.
    /// - `suggestions`: ranked alternates for the unknown-tool arm.
    ///
    /// Arm notes:
    /// - `policyDenied` with no matched id (allowlist boundary or plugin
    ///   default) names the pattern `"fallback"`, matching the audit
    ///   cause-label precedent.
    /// - `elicitationTimeout` maps lossily to `tool_blocked` with pattern
    ///   `"elicitation-timeout"`: the operator never approved, and retrying
    ///   re-prompts, which is the actionable reading.
    /// - `elicitationUnavailable` and `auditFailed` are defects: a backend
    ///   failure (or a saturated wait cap) is infra, not a verdict.
    ///
    /// Declines are NOT an arm: `ElicitationDeclinedError` raises outside
    /// `ScopedInvokeError` (AC-008), and the Executor vocabulary has no
    /// declined/cancelled code — declines throw `ExecutionToolError`
    /// ("requires approval but the request was cancelled/declined by the
    /// user", `tool-invoker.ts:341-351`), exactly like opaque defects, so
    /// no `MCPToolErrorCode` case was added. A serving plane that must
    /// express a decline in-vocabulary maps it lossily to `tool_blocked`
    /// with pattern `"elicitation-declined"` and message
    /// `"Tool blocked by policy: <path>"`; planes that can throw surface
    /// the decline on the defect channel instead.
    public func outcome(path: String, suggestions: [String] = []) -> MCPInvokeFailureOutcome {
        switch self {
        case .principalRequired:
            return .expected(
                MCPToolError.binding(message: "Tool binding failed: no authenticated principal.")
            )
        case .policyDenied(let matchedPolicyId):
            return .expected(MCPToolError.toolBlocked(path: path, pattern: matchedPolicyId ?? "fallback"))
        case .unknownTool:
            return .expected(MCPToolError.toolNotFound(path: path, suggestions: suggestions))
        case .crossResource:
            return .expected(
                MCPToolError.binding(
                    message: "Tool binding failed: the connection is outside the session's bound resource."
                )
            )
        case .invalidArguments(let validation):
            return .expected(MCPToolError.invalidArguments(issues: Self.issues(for: validation)))
        case .elicitationTimeout:
            return .expected(
                MCPToolError(
                    code: .toolBlocked,
                    message: "Tool approval expired before the operator responded: \(path)",
                    details: .toolBlocked(MCPToolBlockedDetails(path: path, pattern: "elicitation-timeout"))
                )
            )
        case .elicitationUnavailable, .auditFailed, .opaque:
            return .defect
        case .credentialFailed(let cause):
            return .expected(Self.authenticationError(for: cause))
        }
    }

    /// Projects one argument-validation failure onto schema-issue shapes.
    /// Total over `MCPArgumentValidationError`; labels only.
    private static func issues(for validation: MCPArgumentValidationError) -> [JSONValue] {
        let issue: (path: String, message: String)
        switch validation {
        case .malformed:
            issue = ("", "Arguments are not a JSON object.")
        case .oversized:
            issue = ("", "Arguments exceed the byte cap.")
        case .tooManyKeys:
            issue = ("", "Arguments hold too many keys.")
        case .badKey(let index):
            issue = ("[\(index)]", "A key name is empty or overlong.")
        case .missingRequired(let key):
            issue = (key, "A required key is missing or null.")
        }
        return [.object(["path": .string(issue.path), "message": .string(issue.message)])]
    }

    /// Maps one broker failure onto the `connection_*` codes. Total over
    /// `SecretsError`; provider-id labels ride the messages (labels only,
    /// never item/field/values). Every arm takes the standard recovery
    /// branch: none of these is a scope or admin-policy wall.
    private static func authenticationError(for cause: SecretsError) -> MCPToolError {
        switch cause {
        case .invalidRef(let provider):
            return .authentication(
                code: .connectionValueMissing,
                message: "Connection credential reference for provider \"\(provider)\" is invalid."
            )
        case .notFound(let provider):
            return .authentication(
                code: .connectionValueMissing,
                message: "Provider \"\(provider)\" holds no credential value for the connection."
            )
        case .denied(let provider):
            return .authentication(
                code: .connectionRejected,
                message: "Provider \"\(provider)\" refused access to the connection credential."
            )
        case .identityRequired:
            return .authentication(
                code: .connectionValueMissing,
                message: "No authenticated principal; no connection credential was resolved."
            )
        case .leaseExpired(let provider):
            return .authentication(
                code: .oauthRefreshFailed,
                message: "Dynamic lease from provider \"\(provider)\" expired; stale values are never served."
            )
        case .providerDown(let provider):
            return .authentication(
                code: .connectionRejected,
                message: "Provider \"\(provider)\" is unreachable."
            )
        case .oversized(let provider):
            return .authentication(
                code: .connectionRejected,
                message: "Credential value from provider \"\(provider)\" exceeds the staging cap."
            )
        case .policyDenied:
            return .authentication(
                code: .connectionRejected,
                message: "Policy denied the connection credential operation."
            )
        case .timeout(let label):
            return .authentication(
                code: .connectionRejected,
                message: "Connection credential operation \"\(label)\" exceeded its budget."
            )
        }
    }
}
