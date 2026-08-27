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
}

@Test func hookHost_allCasesAreDeclarationOrder() {
    #expect(HookHost.allCases.map(\.rawValue) == ["grok", "pi", "opencode", "claude", "openclaw", "hermes", "codex", "cursor"])
}

@Test func hookHost_setupSlotOrderIncludesOpenClawHermesCodexAndCursor() {
    #expect(HookHost.setupSlotOrder.map(\.rawValue) == ["grok", "pi", "opencode", "claude", "openclaw", "hermes", "codex", "cursor"])
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
