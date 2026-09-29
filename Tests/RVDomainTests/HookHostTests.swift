import Foundation
import Testing
@testable import RVDomain

@Test func hookHost_rawValuesAreWireStable() {
    #expect(HookHost.grok.rawValue == "grok")
    #expect(HookHost.pi.rawValue == "pi")
    #expect(HookHost.opencode.rawValue == "opencode")
    #expect(HookHost.claude.rawValue == "claude")
    #expect(HookHost.openclaw.rawValue == "openclaw")
    #expect(HookHost.hermes.rawValue == "hermes")
    #expect(HookHost.codex.rawValue == "codex")
    #expect(HookHost.cursor.rawValue == "cursor")
    #expect(HookHost.antigravity.rawValue == "antigravity")
}

@Test func hookHost_allCasesAreDeclarationOrder() {
    #expect(HookHost.allCases.map(\.rawValue) == ["grok", "pi", "opencode", "claude", "openclaw", "hermes", "codex", "cursor", "antigravity"])
}

@Test func hookHost_setupSlotOrderIncludesOpenClawHermesCodexAndCursor() {
    #expect(HookHost.setupSlotOrder.map(\.rawValue) == ["grok", "pi", "opencode", "claude", "openclaw", "hermes", "codex", "cursor", "antigravity"])
}

@Test func hookHost_codableIsJSONString() throws {
    let data = try JSONEncoder().encode(HookHost.opencode)
    #expect(String(data: data, encoding: .utf8) == "\"opencode\"")
    #expect(try JSONDecoder().decode(HookHost.self, from: data) == .opencode)
}

@Test func hookHost_decodeRejectsUnknownString() {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(HookHost.self, from: Data(#""nope""#.utf8))
    }
}

@Test func hookHost_codexIsAHookHost() {
    #expect(HookHost(rawValue: "codex") == .codex)
    #expect(HookHost.allCases.map(\.rawValue).contains("codex"))
}

@Test func hookHost_cursorIsAHookHost() {
    #expect(HookHost(rawValue: "cursor") == .cursor)
    #expect(HookHost.allCases.map(\.rawValue).contains("cursor"))
}

@Test func agentTagValidator_acceptsHostAndStagingOnlyNames() {
    #expect(AgentTagValidator.isValid("codex"))
    #expect(AgentTagValidator.isValid("muse"))
    #expect(AgentTagValidator.isValid("bogus-hook"))
    #expect(AgentTagValidator.isValid("agent_2.0-x"))
    #expect(AgentTagValidator.isValid(String(repeating: "a", count: 32)))
}

@Test func agentTagValidator_rejectsMalformedTags() {
    #expect(AgentTagValidator.isValid("") == false)
    #expect(AgentTagValidator.isValid("has space") == false)
    #expect(AgentTagValidator.isValid("../escape") == false)
    #expect(AgentTagValidator.isValid("semi;colon") == false)
    #expect(AgentTagValidator.isValid(String(repeating: "a", count: 33)) == false)
}

@Test func hookHost_antigravityIsAHookHost() {
    #expect(HookHost(rawValue: "antigravity") == .antigravity)
    #expect(HookHost.allCases.map(\.rawValue).contains("antigravity"))
}
