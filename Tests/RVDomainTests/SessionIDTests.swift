import Foundation
import Testing
import RVDomain

@Test func sessionID_rejectsEmptyAndAcceptsNonempty() throws {
    #expect(SessionID(validating: "") == nil)
    let session = try #require(SessionID(validating: "s1"))
    #expect(session.rawValue == "s1")
    #expect(SessionID(rawValue: "") == nil)
    #expect(SessionID(rawValue: "s1") != nil)
}

@Test func sessionID_codableRoundTripsNonemptyJSONString() throws {
    let session = try #require(SessionID(validating: "s1"))
    let data = try JSONEncoder().encode(session)
    #expect(String(data: data, encoding: .utf8) == "\"s1\"")
    #expect(try JSONDecoder().decode(SessionID.self, from: data) == session)

    let empty = try JSONEncoder().encode("")
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(SessionID.self, from: empty)
    }
}
