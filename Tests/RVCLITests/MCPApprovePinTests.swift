import Foundation
import RVHistory
import RVMCP
import Synchronization
import Testing
@testable import RVCLI

/// `rv mcp approve` for a call that asks because its tool definition is
/// not trusted: the prompt says so, `--always` does not claim to stop the
/// asking, and the grant stays bound to the definition it was shown for.
@Suite("rv mcp approve pinned tools")
struct MCPApprovePinTests {
    typealias Fixture = MCPCommandTests.Fixture

    static let hostile = "a\u{1B}[2Jb\u{202E}c\u{E0041}d"

    static func hasHidingScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E || $0.value == 0xE0041 }
    }

    static func signed(_ fixture: Fixture, _ policy: MCPToolPolicy) throws {
        _ = try MCPConfiguration(servers: [MCPServerDefinition(name: "github", command: "gh-mcp", tools: policy)])
            .write(configDirectory: fixture.config, signing: .file(configDirectory: fixture.config)).get()
    }

    /// Answers the printed-code challenge with `code` and keeps the prompt.
    static func typing(_ code: String, into prompt: Mutex<String>) -> UserPresence {
        UserPresence { reason, challenge in
            prompt.withLock { $0 = reason }
            guard case .printedCode(let check) = challenge, check(code) else { return .refused("wrong confirmation code") }
            return .confirmed(method: "terminal confirmation code")
        }
    }

    /// M2 (a) and the approve-prompt low: a changed tool is named as
    /// changed with its definition hash, and ESC, U+202E and U+E0041 in the
    /// tool and argument names are escaped in the prompt, the result and
    /// the audit line.
    @Test func thePromptSaysTheToolChangedAndEscapesHidingScalars() async throws {
        let fixture = Fixture()
        try Self.signed(fixture, MCPToolPolicy(allow: ["*"]))
        let store = fixture.environment().approvals
        let binding = MCPToolBinding(definitionHash: "abc123", pinStatus: .changed)
        let ticket = try #require(store.request(
            server: "github", tool: "push\(Self.hostile)", argumentsHash: "h", argumentKeys: ["k\(Self.hostile)"],
            binding: binding))
        let prompt = Mutex("")
        let approved = try await MCPRun.approve(
            id: ticket.id, always: false,
            environment: fixture.environment(presence: Self.typing(try #require(ticket.code), into: prompt))
        ).get()
        let shown = prompt.withLock { $0 }
        #expect(shown.contains("(CHANGED since you trusted it; definition sha256 abc123) "), "\(shown)")
        #expect(shown.hasSuffix(" once"))
        #expect(Self.hasHidingScalar(shown) == false)
        #expect(shown.contains(#"push a\u001b[2Jb‮c1d"#), "\(shown)")
        // Argument names are quoted, so their escapes' backslashes double.
        #expect(shown.contains(#"keys "ka\\u001b[2Jb\\u202ec\\ue0041d""#), "\(shown)")
        #expect(Self.hasHidingScalar(approved) == false)
        #expect(approved.contains(#"a\u001b[2Jb‮c1d"#))

        let line = try String(contentsOf: AuditLog.fileURL(configDirectory: fixture.config), encoding: .utf8)
        #expect(Self.hasHidingScalar(line) == false)
        #expect(line.contains(#"‮"#) || line.contains(#"‮"#))
        #expect(fixture.approvalEvents().last?.subject == "github/push\(Self.hostile)")

        // The grant is bound to the definition the prompt named.
        #expect(store.consumeGrant(
            server: "github", tool: "push\(Self.hostile)", argumentsHash: "h", argumentKeys: ["k\(Self.hostile)"],
            binding: MCPToolBinding(definitionHash: "other", pinStatus: .changed)) == .none)
        #expect(store.consumeGrant(
            server: "github", tool: "push\(Self.hostile)", argumentsHash: "h", argumentKeys: ["k\(Self.hostile)"],
            binding: binding) == .granted(id: ticket.id))
    }

    /// `--always` on a tool mcp.json already allows, asking only because
    /// its definition is not trusted, approves once, leaves mcp.json alone
    /// and points at `rv mcp trust`.
    @Test func alwaysOnAToolThatAsksOnlyForPinningApprovesOnce() async throws {
        let fixture = Fixture()
        try Self.signed(fixture, MCPToolPolicy(allow: ["search"]))
        let config = MCPConfiguration.fileURL(configDirectory: fixture.config)
        let before = try Data(contentsOf: config)
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "github", tool: "search", argumentsHash: "h", argumentKeys: [],
            binding: MCPToolBinding(definitionHash: "def456", pinStatus: .new)))
        let prompt = Mutex("")
        let approved = try await MCPRun.approve(
            id: ticket.id, always: true,
            environment: fixture.environment(presence: Self.typing(try #require(ticket.code), into: prompt))
        ).get()
        #expect(approved == "approved github search once; mcp.json already allows it: it asks because its tool definition is not trusted (not yet trusted). Run `rv mcp trust` to review and pin it\n")
        let shown = prompt.withLock { $0 }
        #expect(shown.contains("(not yet trusted; definition sha256 def456) "), "\(shown)")
        #expect(shown.hasSuffix(" once"), "\(shown)")
        #expect(try Data(contentsOf: config) == before)
        #expect(fixture.approvalEvents().last?.detail["always"] == "false")
    }

    /// `--always` on an `ask` tool that is also untrusted adds it to the
    /// allow list but says it keeps asking until `rv mcp trust`.
    @Test func alwaysOnAnUntrustedAskToolSaysItStillAsks() async throws {
        let fixture = Fixture()
        try Self.signed(fixture, MCPToolPolicy(ask: ["push"]))
        let store = fixture.environment().approvals
        let ticket = try #require(store.request(
            server: "github", tool: "push", argumentsHash: "h", argumentKeys: [],
            binding: MCPToolBinding(definitionHash: "def456", pinStatus: .changed)))
        let prompt = Mutex("")
        let approved = try await MCPRun.approve(
            id: ticket.id, always: true,
            environment: fixture.environment(presence: Self.typing(try #require(ticket.code), into: prompt))
        ).get()
        #expect(approved == "approved github push once and added it to its allow list in mcp.json; it still asks because its tool definition is not trusted (CHANGED since you trusted it). Run `rv mcp trust` to review and pin it\n")
        let updated = try MCPRun.configuration(fixture.environment()).get()
        #expect(updated.server(named: "github")?.tools.allow == ["push"])
    }
}
