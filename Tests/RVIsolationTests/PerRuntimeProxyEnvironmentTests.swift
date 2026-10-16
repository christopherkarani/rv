#if os(macOS)
import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// T4 per-runtime proxy env + review identity (Item 2: CON-2-3, PAT-2-5,
/// GUD-2-6; AC-2 per-runtime isolation).
///
/// Each cage environment carries its own runtime's proxy binding: the
/// loopback port plus the supervisor-minted credential as URL userinfo
/// (stock HTTP clients send `*_PROXY` userinfo as Basic
/// `Proxy-Authorization`, which the credentialed proxy authenticates
/// against that runtime's grant alone). Frozen prepared environments
/// never carry proxy variables; dispatch re-stamps the live binding.
/// Admitted one-shot commands inherit the owning runtime's port but no
/// credential (narrower grant). Borrowed shape: OpenShell's
/// workload-without-network plus supervisor-owned upstream
/// (https://raw.githubusercontent.com/NVIDIA/OpenShell/main/crates/openshell-driver-docker/README.md).
///
/// Hermetic: environments are built from synthetic host maps (never the
/// live process environment), and no test spawns.
@Suite("Per-runtime proxy environment")
struct PerRuntimeProxyEnvironmentTests {
    private static let token = String(repeating: "ab", count: 32)

    @Test func credentialRidesProxyURLUserinfo() {
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            egressProxyPort: 39321,
            egressProxyCredential: EgressProxyCredential(rawValue: Self.token),
            hostEnvironment: [:]
        )
        let url = "http://\(Self.token)@127.0.0.1:39321"
        #expect(values.contains("HTTPS_PROXY=\(url)"))
        #expect(values.contains("HTTP_PROXY=\(url)"))
        #expect(values.contains("https_proxy=\(url)"))
        #expect(values.contains("http_proxy=\(url)"))
        #expect(values.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        #expect(values.contains("no_proxy=localhost,127.0.0.1,::1"))
    }

    @Test func stampedUserinfoAuthenticatesAgainstProxyParser() {
        // Contract pin: the userinfo this file stamps must parse back
        // through the proxy's own credential extractor the way a stock
        // client presents it (Basic over userinfo).
        let values = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit,
            egressProxyPort: 39321,
            egressProxyCredential: EgressProxyCredential(rawValue: Self.token),
            hostEnvironment: [:]
        )
        let entry = try! #require(values.first { $0.hasPrefix("HTTPS_PROXY=") })
        let url = String(entry.dropFirst("HTTPS_PROXY=".count))
        let userinfo = try! #require(URL(string: url)?.user)
        let presented = Data("\(userinfo):x".utf8).base64EncodedString()
        let header = "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic \(presented)\r\n\r\n"
        #expect(EgressProxy.proxyCredentialToken(header: header) == Self.token)
    }

    @Test func malformedCredentialFallsBackToPortOnlyURL() {
        let hostile = [
            "tok@en", "tok/en", "tok:en", "tok?en", "tok#en", "tok en",
            "tok%40en", "", String(repeating: "a", count: 257), "tökén",
        ]
        for raw in hostile {
            let values = containedRuntimeEnvironment(
                workspace: "/tmp/ws", io: .inherit,
                egressProxyPort: 39321,
                egressProxyCredential: EgressProxyCredential(rawValue: raw),
                hostEnvironment: [:]
            )
            // Fail closed to the port-only shape: a smuggling token must
            // never rewrite the URL authority, and in credentialed mode
            // the bare URL simply 407s.
            #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:39321"))
            #expect(values.allSatisfy { $0.contains("@") == false })
            #expect(values.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        }
    }

    @Test func restampSubstitutesLivePortIntoFrozenEnvironment() {
        let frozen = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit, hostEnvironment: [:]
        )
        #expect(frozen.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
        let live = restampEgressProxyVariables(frozen, port: 41111)
        #expect(live.contains("HTTPS_PROXY=http://127.0.0.1:41111"))
        #expect(live.contains("HTTP_PROXY=http://127.0.0.1:41111"))
        #expect(live.contains("https_proxy=http://127.0.0.1:41111"))
        #expect(live.contains("http_proxy=http://127.0.0.1:41111"))
        #expect(live.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        #expect(live.contains("no_proxy=localhost,127.0.0.1,::1"))
        // Everything else survives byte for byte.
        for entry in frozen {
            #expect(live.contains(entry))
        }
    }

    @Test func restampDropsStaleFrozenProxyVarsOnRotation() {
        let stale = [
            "PATH=/usr/bin:/bin",
            "HTTPS_PROXY=http://stale@127.0.0.1:10001",
            "https_proxy=http://127.0.0.1:10001",
            "ALL_PROXY=http://127.0.0.1:10001",
            "NO_PROXY=localhost",
            "HOME=/tmp/ws",
        ]
        let live = restampEgressProxyVariables(
            stale, port: 42222,
            credential: EgressProxyCredential(rawValue: Self.token)
        )
        #expect(live.contains("PATH=/usr/bin:/bin"))
        #expect(live.contains("HOME=/tmp/ws"))
        let url = "http://\(Self.token)@127.0.0.1:42222"
        #expect(live.contains("HTTPS_PROXY=\(url)"))
        #expect(live.contains("HTTP_PROXY=\(url)"))
        #expect(live.contains("https_proxy=\(url)"))
        #expect(live.contains("http_proxy=\(url)"))
        #expect(live.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        #expect(live.allSatisfy { $0.contains("10001") == false })
        #expect(live.allSatisfy { $0.contains("stale") == false })
        #expect(live.allSatisfy { $0.hasPrefix("ALL_PROXY=") == false })
        #expect(live.allSatisfy { $0.hasPrefix("all_proxy=") == false })
    }

    @Test func restampWithNilPortLeavesNoRoute() {
        let frozen = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .inherit, hostEnvironment: [:]
        )
        for port in [nil, 0, -1, 70_000] {
            let live = restampEgressProxyVariables(frozen, port: port)
            #expect(live.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
            #expect(live.allSatisfy { $0.hasPrefix("HTTP_PROXY=") == false })
            #expect(live.allSatisfy { $0.hasPrefix("https_proxy=") == false })
            #expect(live.allSatisfy { $0.hasPrefix("http_proxy=") == false })
            #expect(live.allSatisfy { $0.hasPrefix("NO_PROXY=") == false })
            #expect(live.allSatisfy { $0.hasPrefix("no_proxy=") == false })
            #expect(live == frozen)
        }
    }

    @Test func admittedOneShotInheritsPortWithoutCredential() {
        // Narrower-grant decision (spec §9): a one-shot shares the owning
        // runtime's proxy address (loopback the seatbelt rule already
        // admits: no new route) but holds no credential, so the
        // credentialed proxy 407s its CONNECTs while loopback-direct
        // keeps working. One-shots execute single gate-allowed shell
        // effects; they must not borrow the runtime's network grant.
        var launch = AdmittedLaunchContext(
            plan: compileContainedPlan(workspace: WorkingDirectory(rawValue: "/tmp/ws")!),
            profileSource: "(deny default)",
            workspacePath: "/tmp/ws"
        )
        launch.egressProxyPort = 43333
        let values = admittedOneShotEnvironment(launch: launch, hostEnvironment: [:])
        #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:43333"))
        #expect(values.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        #expect(values.allSatisfy { $0.contains("@") == false })
        launch.egressProxyPort = nil
        let closed = admittedOneShotEnvironment(launch: launch, hostEnvironment: [:])
        #expect(closed.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
    }
}
#endif
