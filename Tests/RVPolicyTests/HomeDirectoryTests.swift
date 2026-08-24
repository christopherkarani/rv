import Foundation
import Testing
import RVPolicy

@Suite struct HomeDirectoryTests {
    @Test func validatingRejectsEmptyString() {
        #expect(HomeDirectory(validating: "") == nil)
    }

    @Test func validatingAcceptsNonEmptyPath() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-home"))
        #expect(home.rawValue == "/tmp/rv-home")
    }

    @Test func rawRepresentableInitFailsOnEmpty() {
        #expect(HomeDirectory(rawValue: "") == nil)
        #expect(HomeDirectory(rawValue: "/tmp/rv-home") != nil)
    }

    @Test func codableRoundTripsAndRejectsEmpty() throws {
        let home = try #require(HomeDirectory(validating: "/tmp/rv-home"))
        let data = try JSONEncoder().encode(home)
        #expect(try JSONDecoder().decode(HomeDirectory.self, from: data) == home)

        let empty = try JSONEncoder().encode("")
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HomeDirectory.self, from: empty)
        }
    }
}
