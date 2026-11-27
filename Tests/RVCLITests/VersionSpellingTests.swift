import Testing
@testable import RVCLI

struct VersionSpellingTests {
    @Test func dashCapitalVAndVersionPrintTheVersion() {
        #expect(VersionSpelling.normalized(["-V"]) == ["--version"])
        #expect(VersionSpelling.normalized(["version"]) == ["--version"])
        #expect(UnknownCommand.message(arguments: VersionSpelling.normalized(["version"])) == nil)
    }

    @Test func otherArgumentsAreUnchanged() {
        #expect(VersionSpelling.normalized([]) == [])
        #expect(VersionSpelling.normalized(["version", "--json"]) == ["version", "--json"])
        #expect(VersionSpelling.normalized(["test", "-V"]) == ["test", "-V"])
        #expect(VersionSpelling.normalized(["--version"]) == ["--version"])
    }
}
