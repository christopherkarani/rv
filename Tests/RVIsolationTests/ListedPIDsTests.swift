#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVIsolation

/// `proc_listchildpids` and `proc_listpgrppids` return a pid count, not a
/// byte count. Dividing by four dropped every list shorter than four pids.
@Suite("ListedPIDs", .serialized)
struct ListedPIDsTests {
    @Test func aSingleChildIsListed() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        #expect(listedPIDs(proc_listchildpids, getpid()).contains(child.processIdentifier))
    }

    @Test func theCallerIsListedInItsOwnGroup() {
        #expect(listedPIDs(proc_listpgrppids, getpgrp()).contains(getpid()))
    }
}
#endif
