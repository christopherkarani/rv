import Testing

@testable import RVOperatorUI

@Suite("Arrival ledger")
struct ArrivalLedgerTests {
    @Test func baselineMarksExistingRowsSeenAndClearsUnseen() {
        var ledger = ArrivalLedger<String>()
        ledger.observe(["a"])
        ledger.baseline(["a", "b"])
        #expect(ledger.unseen.isEmpty)
        ledger.observe(["a", "b"])
        #expect(ledger.unseen.isEmpty)
    }

    @Test func observeFlagsNeverListedIDs() {
        var ledger = ArrivalLedger<String>()
        ledger.baseline(["a"])
        ledger.observe(["a", "b"])
        #expect(ledger.unseen == ["b"])
    }

    @Test func observeDropsVanishedIDsFromUnseen() {
        var ledger = ArrivalLedger<String>()
        ledger.observe(["b"])
        ledger.observe([])
        #expect(ledger.unseen.isEmpty)
        // Once listed, a returning ID is not a new arrival.
        ledger.observe(["b"])
        #expect(ledger.unseen.isEmpty)
    }

    @Test func openMarksSeen() {
        var ledger = ArrivalLedger<String>()
        ledger.observe(["a", "b"])
        ledger.open("a")
        #expect(ledger.unseen == ["b"])
    }

    @Test func emptyFirstBaselineLeavesLaterRowsUnseen() {
        var ledger = ArrivalLedger<String>()
        ledger.baseline([])
        ledger.observe(["a"])
        #expect(ledger.unseen == ["a"])
    }
}
