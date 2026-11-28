import Testing
import RVDomain
@testable import RVService

/// G6b: the no-owner enable gate (`PacksFacade.enableTightening`). The
/// real enable path cannot loosen today, so the gate is driven directly.
@Suite struct PacksTighteningTests {
    private let git = PackID(rawValue: "core.git")
    private let redis = PackID(rawValue: "database.redis")

    @Test func droppingAPackThatWasOn_throwsWouldLoosen() {
        #expect(throws: PacksCommandError.wouldLoosen) {
            try PacksFacade.requireTightens(from: [git, redis], to: [redis])
        }
    }

    @Test func swappingOnePackForAnother_throwsWouldLoosen() {
        #expect(throws: PacksCommandError.wouldLoosen) {
            try PacksFacade.requireTightens(from: [git], to: [redis])
        }
    }

    @Test func addingOrKeepingPacks_passes() throws {
        try PacksFacade.requireTightens(from: [git], to: [git, redis])
        try PacksFacade.requireTightens(from: [git], to: [git])
        try PacksFacade.requireTightens(from: [], to: [])
    }
}
