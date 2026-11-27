import Testing
import RVDomain
@testable import RVHooks

/// Hook deny text that reads command words from `CommandVocabulary` is
/// byte-identical to the literal sentences it replaced.
@Suite("Host deny text vocabulary pins")
struct HostDenyVocabularyPinTests {
    @Test func unlockSentencesAreUnchanged() throws {
        let code = try #require(AllowOnceUnlockCode(validating: "a1b2c3"))
        #expect(ttyUnlockHint == "Run it in Terminal, or rv allow-once.")
        #expect(
            unlockLine(for: code)
                == "Paste in Terminal to allow once: rv allow-once a1b2c3. This unlocks the reviewed command once, including its sudo, env, and path spellings."
        )
        #expect(
            earlierPendingUnlockLine
                == "A one-shot unlock is already pending for this command. Paste the earlier rv allow-once code in Terminal."
        )
    }

    @Test func unlockCodeIsFoundAfterTheTableSpelling() {
        #expect(allowOnceUnlockCode(in: "RV · Blocked. Paste: rv allow-once a1b2c3. Why.")?.rawValue == "a1b2c3")
        #expect(allowOnceUnlockCode(in: "rv allow-once") == nil)
        #expect(allowOnceUnlockCode(in: "rv unlock a1b2c3") == nil)
    }
}
