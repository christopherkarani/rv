import Testing
@testable import RVDomain

@Test func egressPolicyAllowsExactHostsOn443() {
    let policy = EgressHostPolicy.agentAPIs
    #expect(policy.allows(host: "api.anthropic.com", port: 443))
    #expect(policy.allows(host: "api.openai.com", port: 443))
    #expect(policy.allows(host: "API.ANTHROPIC.COM", port: 443))
    #expect(policy.allows(host: "api.anthropic.com.", port: 443))
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
