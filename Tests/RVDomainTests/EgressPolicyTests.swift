import Testing
@testable import RVDomain

@Test func egressPolicyAllowsExactHostsOn443() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allows(host: "api.anthropic.com", port: 443))
    #expect(policy.allows(host: "api.openai.com", port: 443))
    #expect(policy.allows(host: "chatgpt.com", port: 443))
    #expect(policy.allows(host: "auth.openai.com", port: 443))
    #expect(policy.allows(host: "api.meta.ai", port: 443))
    #expect(policy.allows(host: "auth.meta.com", port: 443))
    #expect(policy.allows(host: "opencode.ai", port: 443))
    #expect(policy.allows(host: "models.opencode.ai", port: 443))
    #expect(policy.allows(host: "API.ANTHROPIC.COM", port: 443))
    #expect(policy.allows(host: "api.anthropic.com.", port: 443))
}

@Test func egressPolicyAdmitsLoopbackTargetsOnAnyPort() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allowsLoopbackTarget(host: "localhost", port: 10100))
    #expect(policy.allowsLoopbackTarget(host: "localhost", port: 443))
    #expect(policy.allowsLoopbackTarget(host: "LOCALHOST", port: 3000))
    #expect(policy.allowsLoopbackTarget(host: "localhost.", port: 3000))
    #expect(policy.allowsLoopbackTarget(host: "127.0.0.1", port: 10100))
    #expect(policy.allowsLoopbackTarget(host: "127.0.0.2", port: 8080))
    #expect(policy.allowsLoopbackTarget(host: "128.0.0.1", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "1.2.3.4", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "example.com", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "localhost.evil.com", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "[::1]", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "user@localhost", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "", port: 10100) == false)
    #expect(policy.allowsLoopbackTarget(host: "localhost", port: 0) == false)
    #expect(policy.allowsLoopbackTarget(host: "localhost", port: 70_000) == false)
}

@Test func egressPolicyRejectsWrongPortAndUnknownHosts() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allows(host: "api.anthropic.com", port: 80) == false)
    #expect(policy.allows(host: "api.anthropic.com", port: 8443) == false)
    #expect(policy.allows(host: "example.com", port: 443) == false)
    #expect(policy.allows(host: "", port: 443) == false)
}

@Test func egressPolicyRejectsSubdomainsInV1() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allows(host: "evil.api.anthropic.com", port: 443) == false)
    #expect(policy.allows(host: "api.anthropic.com.evil.com", port: 443) == false)
}

@Test func egressPolicyRejectsIPAndUserinfoBypassShapes() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allows(host: "1.2.3.4", port: 443) == false)
    #expect(policy.allows(host: "[::1]", port: 443) == false)
    #expect(policy.allows(host: "user@api.anthropic.com", port: 443) == false)
    #expect(policy.allows(host: "api.anthropic.com:443", port: 443) == false)
    #expect(policy.allows(host: "api.anthropic.com ", port: 443) == false)
    #expect(policy.allows(host: "api..anthropic.com", port: 443) == false)
    #expect(policy.allows(host: ".api.anthropic.com", port: 443) == false)
    #expect(policy.allows(host: "localhost", port: 443) == false)
    #expect(policy.allows(host: String(repeating: "a", count: 64) + ".com", port: 443) == false)
}
