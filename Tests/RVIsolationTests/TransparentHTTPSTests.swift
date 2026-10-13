import Testing
@testable import RVIsolation

@Suite("Transparent HTTPS spike")
struct TransparentHTTPSTests {
    @Test func terminatesOnlyTheExactUpstreamHost() {
        let hosts = ["api.openai.com", "API.Example.com."]
        #expect(TransparentHTTPS.decision(host: "api.openai.com", secretUpstreams: hosts) == .terminate)
        #expect(TransparentHTTPS.decision(host: "API.Example.com", secretUpstreams: hosts) == .terminate)
        #expect(TransparentHTTPS.decision(host: "evil.api.openai.com", secretUpstreams: hosts) == .tunnel)
        #expect(TransparentHTTPS.decision(host: "openai.com", secretUpstreams: hosts) == .tunnel)
        #expect(TransparentHTTPS.decision(host: "api.openai.com.evil.test", secretUpstreams: hosts) == .tunnel)
        #expect(TransparentHTTPS.decision(host: "127.0.0.1", secretUpstreams: hosts) == .tunnel)
        #expect(TransparentHTTPS.decision(host: "localhost", secretUpstreams: hosts) == .tunnel)
        #expect(TransparentHTTPS.decision(host: "api.openai.com", secretUpstreams: []) == .tunnel)
    }
}
