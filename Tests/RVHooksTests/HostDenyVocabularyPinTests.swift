import Testing
import RVDomain
@testable import RVHooks

/// Stop text reads command words from `CommandVocabulary`, so the A4 rename
/// (`rv unlock`) switches every stop at once.
@Suite("Host deny text vocabulary pins")
struct HostDenyVocabularyPinTests {
    @Test func unlockLinesUseTheTableSpelling() throws {
        let code = try #require(AllowOnceUnlockCode(validating: "a1b2c3"))
        let unlock = CommandVocabulary.Command.allowOnce.invocation
        #expect(unlockLine(for: code) == "ask your user to run  \(unlock) a1b2c3  (you can wait: rv wait a1b2c3)")
        #expect(earlierPendingUnlockLine() == "ask your user to run the earlier code with  \(unlock)")
        #expect(
            ownerRunsLine(CommandVocabulary.Command.doctor.invocation)
                == "ask your user to run  rv doctor"
        )
        #expect(unlock == "rv allow-once")
    }

    @Test func unlockCodeIsFoundAfterTheTableSpelling() {
        #expect(allowOnceUnlockCode(in: "who     ask Chris to run  rv allow-once a1b2c3")?.rawValue == "a1b2c3")
        #expect(allowOnceUnlockCode(in: "rv allow-once") == nil)
        #expect(allowOnceUnlockCode(in: "rv unlock a1b2c3") == nil)
    }

    @Test func verdictWordsAreTheTableGlyph() {
        let notice = StopNotice(subject: "x", rule: "a.b/c", why: "w", who: "o")
        #expect(notice.verdictLine.hasPrefix(
            "\(CommandVocabulary.Glyph.stopped.rawValue) \(CommandVocabulary.Glyph.stopped.word)   "))
    }
}
