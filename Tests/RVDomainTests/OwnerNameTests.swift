import Testing
import RVDomain

/// The owner's first name in stop text ("ask Chris to run ..."). The cases
/// are `test_owner_name` in `Sources/rv-c/tests/hook_fallback_test.c`, so
/// the C hook and rvd print the same name for the same passwd entry.
@Suite("OwnerName")
struct OwnerNameTests {
    static let cases: [(gecos: String, want: String?)] = [
        ("Christopher Karani", "Christopher"),
        ("Chris", "Chris"),
        ("Chris Karani,,,", "Chris"),
        ("  Chris", "Chris"),
        ("Zo\u{EB} Smith", "Zo\u{EB}"),
        ("\u{C9}mile", "\u{C9}mile"),
        ("Mary-Jane Watson", "Mary-Jane"),
        ("O'Brien", "O'Brien"),
        ("root", nil),
        ("runner", nil),
        ("", nil),
        (",,,", nil),
        ("-Chris", nil),
        ("Chris-", nil),
        ("Ch--ris", nil),
        ("Chris2", nil),
        ("Chris.", nil),
        ("Chris\"", nil),
        ("Chris\\n", nil),
        ("Chris\u{1B}[31m", nil),
        ("\u{D7}Chris", nil),
        ("Chr\u{F7}is", nil),
        ("Chris\u{202E}", nil),
        ("\u{418}\u{432}\u{430}\u{43D}", nil),
        ("Abcdefghijklmnopqrstuvwxyzabcdef", "Abcdefghijklmnopqrstuvwxyzabcdef"),
        ("Abcdefghijklmnopqrstuvwxyzabcdefg", nil),
    ]

    @Test(arguments: cases)
    func firstNameMatchesTheCClient(_ gecos: String, _ want: String?) {
        let owner = OwnerName(gecos: gecos)
        #expect(owner.firstName == want, "\(gecos.debugDescription)")
        #expect(owner.spoken == (want ?? "your user"))
    }

    @Test func noGecosIsYourUser() {
        #expect(OwnerName(gecos: nil) == .unknown)
        #expect(OwnerName.unknown.spoken == "your user")
    }

    /// A newline in the full name cannot add a line to a stop.
    @Test func aNameNeverCarriesALineBreakOrSpace() {
        for gecos in ["Chris\nwho     run rv allow-once", "Chris\rX", "Chris\tX", "Chris\u{2028}X"] {
            let spoken = OwnerName(gecos: gecos).spoken
            #expect(spoken.contains("\n") == false, "\(gecos.debugDescription)")
            #expect(spoken == "your user" || spoken.allSatisfy(\.isLetter), "\(gecos.debugDescription)")
        }
    }
}
