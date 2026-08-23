import Foundation
import Testing
@testable import RVDomain

@Test func hookHost_rawValuesAreWireStable() {
    #expect(HookHost.grok.rawValue == "grok")
    #expect(HookHost.pi.rawValue == "pi")
    #expect(HookHost.opencode.rawValue == "opencode")
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
