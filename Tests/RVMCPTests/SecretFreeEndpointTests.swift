import Foundation
import Testing
@testable import RVMCP

/// The one spelling table at the endpoint classification seam. Both
/// adapters (`MCPRemoteServer.endpointProblem` here, audit forwarding in
/// RVCLI tested against the same spellings) must accept or refuse exactly
/// where the classification does; each adapter keeps its own sentences.
@Suite("SecretFreeEndpoint classification")
struct SecretFreeEndpointTests {
    static let spellings: [(String, SecretFreeEndpointProblem?)] = [
        // Accept: https anywhere, http only to parsed loopback.
        ("https://mcp.example.com/mcp", nil),
        ("https://mcp.example.com/mcp?v=1", nil),
        ("http://localhost:9/mcp", nil),
        ("http://127.0.0.1/mcp", nil),
        ("http://127.0.0.2/mcp", nil),
        ("http://[::1]:8080/sse", nil),
        ("http://[::ffff:127.0.0.1]/mcp", nil),
        // Percent-encoded host, canonical once decoded: accepted today.
        ("https://%31%32%37.0.0.1/mcp", nil),
        // Scheme: plain http away from loopback, other schemes, and the
        // trailing-dot loopback lookalike the parsed check does not admit.
        ("http://mcp.example.com/mcp", .scheme),
        ("ftp://mcp.example.com/mcp", .scheme),
        ("http://localhost./mcp", .scheme),
        // Non-canonical IP spellings (REQ-T6 named divergence: audit
        // forwarding refuses these now too, loopback aliases included).
        ("http://127.000.0.1/mcp", .nonCanonicalHost),
        ("https://127.000.0.1/mcp", .nonCanonicalHost),
        ("http://127.1/mcp", .nonCanonicalHost),
        ("http://2130706433/mcp", .nonCanonicalHost),
        ("http://0x7f000001/mcp", .nonCanonicalHost),
        ("http://0177.0.0.1/mcp", .nonCanonicalHost),
        ("https://127.1/mcp", .nonCanonicalHost),
        ("http://[fe80::1%25eth0]/mcp", .nonCanonicalHost),
        ("https://%31%32%37.000.0.1/mcp", .nonCanonicalHost),
        // Credentials and fragment.
        ("https://user:pass@mcp.example.com/mcp", .credentials),
        ("https://user@mcp.example.com/mcp", .credentials),
        ("https://mcp.example.com/mcp#section", .fragment),
        // Secrets by where they hide, percent-encoded host included.
        ("https://supersecretpassword%40evil.example/hook", .hostSecret),
        ("https://supersecretpassword%2540evil.example/hook", .hostSecret),
        ("https://mcp.example.com/hook?api_key=zzz", .querySecret),
        ("https://mcp.example.com/hook?next=https://user:supersecretpassword@collector.example", .querySecret),
        ("https://mcp.example.com/https://user:supersecretpassword@evil.example/hook", .pathSecret),
        // Userinfo spelling split across the path/query boundary, visible
        // to neither per-part predicate on its own.
        ("https://mcp.example.com/user:?z@collector.example", .userinfoSpelling),
    ]

    @Test func spellingTableClassifiesEveryRow() throws {
        for (spelling, expected) in Self.spellings {
            let url = try #require(URL(string: spelling), "\(spelling)")
            #expect(SecretFreeEndpoint.problemKind(for: url) == expected, "\(spelling)")
            // The raw-spelling entry the audit adapter crosses agrees.
            #expect(SecretFreeEndpoint.problemKind(url: url, rawSpelling: spelling) == expected, "\(spelling)")
        }
    }

    @Test func mcpAdapterKeepsItsSentencesPerKind() throws {
        let sentences: [(String, String?)] = [
            ("https://mcp.example.com/mcp", nil),
            ("http://mcp.example.com/mcp", "must be https (http only to localhost)"),
            ("http://127.000.0.1/mcp", "must name its host as a canonical IP address or DNS name"),
            ("https://user:pass@mcp.example.com/mcp", "must be given without credentials (send them as headers with ${secret:NAME})"),
            ("https://mcp.example.com/mcp#section", "must not have a fragment"),
            ("https://supersecretpassword%40evil.example/hook", "must not carry a secret in its host (send it as a header with ${secret:NAME})"),
            ("https://mcp.example.com/hook?api_key=zzz", "must not carry a secret in its query (send it as a header with ${secret:NAME})"),
            ("https://mcp.example.com/https://user:supersecretpassword@evil.example/hook", "must not carry a secret in its path (send it as a header with ${secret:NAME})"),
            ("https://mcp.example.com/user:?z@collector.example", "must not carry a secret in its path (send it as a header with ${secret:NAME})"),
        ]
        for (spelling, expected) in sentences {
            let url = try #require(URL(string: spelling), "\(spelling)")
            #expect(MCPRemoteServer.endpointProblem(url) == expected, "\(spelling)")
        }
        // Every refused classification above is refused here too, and the
        // sentence never echoes the secret it refused.
        for (spelling, kind) in Self.spellings {
            let url = try #require(URL(string: spelling), "\(spelling)")
            #expect((MCPRemoteServer.endpointProblem(url) != nil) == (kind != nil), "\(spelling)")
            #expect(MCPRemoteServer.endpointProblem(url)?.contains("supersecretpassword") != true, "\(spelling)")
        }
    }

    @Test func missingSchemeOrHostIsMalformedNotScheme() throws {
        for spelling in ["mcp.example.com/mcp", "https:///mcp", "/mcp"] {
            guard let url = URL(string: spelling) else { continue }
            #expect(SecretFreeEndpoint.problemKind(for: url) == .malformed, "\(spelling)")
            #expect(MCPRemoteServer.endpointProblem(url) == "must be https (http only to localhost)", "\(spelling)")
        }
    }
}
