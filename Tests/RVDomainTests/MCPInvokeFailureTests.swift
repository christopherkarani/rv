import Testing
@testable import RVDomain

@Suite("MCPInvokeFailure")
struct MCPInvokeFailureTests {
    @Test func principalRequiredBinds() {
        #expect(
            MCPInvokeFailure.principalRequired.outcome(path: "i.o.c.t")
                == .expected(
                    MCPToolError.binding(
                        message: "Tool binding failed: no authenticated principal."
                    )
                )
        )
    }

    @Test func policyDeniedNamesRuleOrFallback() {
        #expect(
            MCPInvokeFailure.policyDenied(matchedPolicyId: "r1").outcome(path: "i.o.c.t")
                == .expected(MCPToolError.toolBlocked(path: "i.o.c.t", pattern: "r1"))
        )
        #expect(
            MCPInvokeFailure.policyDenied(matchedPolicyId: nil).outcome(path: "i.o.c.t")
                == .expected(MCPToolError.toolBlocked(path: "i.o.c.t", pattern: "fallback"))
        )
    }

    @Test func unknownToolCarriesSuggestions() {
        #expect(
            MCPInvokeFailure.unknownTool.outcome(path: "i.o.c.t", suggestions: ["i.o.c.u"])
                == .expected(MCPToolError.toolNotFound(path: "i.o.c.t", suggestions: ["i.o.c.u"]))
        )
        #expect(
            MCPInvokeFailure.unknownTool.outcome(path: "i.o.c.t")
                == .expected(MCPToolError.toolNotFound(path: "i.o.c.t", suggestions: []))
        )
    }

    @Test func crossResourceBinds() {
        #expect(
            MCPInvokeFailure.crossResource.outcome(path: "i.o.c.t")
                == .expected(
                    MCPToolError.binding(
                        message: "Tool binding failed: the connection is outside the session's bound resource."
                    )
                )
        )
    }

    @Test func invalidArgumentsProjectsEveryValidationArm() {
        let cases: [(MCPArgumentValidationError, String, String)] = [
            (.malformed, "", "Arguments are not a JSON object."),
            (.oversized, "", "Arguments exceed the byte cap."),
            (.tooManyKeys, "", "Arguments hold too many keys."),
            (.badKey(index: 2), "[2]", "A key name is empty or overlong."),
            (.missingRequired(key: "tool"), "tool", "A required key is missing or null."),
        ]
        for (validation, path, message) in cases {
            #expect(
                MCPInvokeFailure.invalidArguments(validation).outcome(path: "i.o.c.t")
                    == .expected(
                        MCPToolError.invalidArguments(
                            issues: [.object(["path": .string(path), "message": .string(message)])]
                        )
                    ),
                "\(validation)",
            )
        }
    }

    @Test func elicitationTimeoutIsLossyBlock() {
        #expect(
            MCPInvokeFailure.elicitationTimeout.outcome(path: "i.o.c.t")
                == .expected(
                    MCPToolError(
                        code: .toolBlocked,
                        message: "Tool approval expired before the operator responded: i.o.c.t",
                        details: .toolBlocked(
                            MCPToolBlockedDetails(path: "i.o.c.t", pattern: "elicitation-timeout")
                        )
                    )
                )
        )
    }

    @Test func infraArmsAreDefects() {
        for failure: MCPInvokeFailure in [.elicitationUnavailable, .auditFailed, .opaque] {
            #expect(failure.outcome(path: "i.o.c.t") == .defect, "\(failure)")
        }
    }

    @Test func credentialFailedMapsEverySecretsArm() {
        let cases: [(SecretsError, MCPToolErrorCode, String)] = [
            (.invalidRef("file"), .connectionValueMissing, "Connection credential reference for provider \"file\" is invalid."),
            (.notFound("keychain"), .connectionValueMissing, "Provider \"keychain\" holds no credential value for the connection."),
            (.denied("vault-http"), .connectionRejected, "Provider \"vault-http\" refused access to the connection credential."),
            (.identityRequired, .connectionValueMissing, "No authenticated principal; no connection credential was resolved."),
            (.leaseExpired("env"), .oauthRefreshFailed, "Dynamic lease from provider \"env\" expired; stale values are never served."),
            (.providerDown("exec"), .connectionRejected, "Provider \"exec\" is unreachable."),
            (.oversized("file"), .connectionRejected, "Credential value from provider \"file\" exceeds the staging cap."),
            (.policyDenied, .connectionRejected, "Policy denied the connection credential operation."),
            (.timeout("resolve"), .connectionRejected, "Connection credential operation \"resolve\" exceeded its budget."),
        ]
        for (cause, code, message) in cases {
            let outcome = MCPInvokeFailure.credentialFailed(cause).outcome(path: "i.o.c.t")
            guard case .expected(let error) = outcome else {
                Issue.record("expected ToolError for \(cause)")
                continue
            }
            #expect(error.code == code, "\(cause)")
            #expect(error.message == message, "\(cause)")
            #expect(error.retryable == false, "\(cause)")
            guard case .authentication(let details) = error.details else {
                Issue.record("expected authentication details for \(cause)")
                continue
            }
            #expect(details.category == "authentication", "\(cause)")
            #expect(details.recovery == .standard(), "\(cause)")
        }
    }
}
