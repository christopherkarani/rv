import Testing
import RVDomain
@testable import RVEngine

@Suite("RedirectOperator grammar (T4)")
struct RedirectOperatorTests {
    @Test("bare redirect-out words match", arguments: [
        ">", ">>", ">|", ">&", "<>", "&>", "&>>",
        "2>", "10>>", "2>|", "2>&", "0<>", "1>>",
    ])
    func bareWordMatches(word: String) {
        #expect(RedirectOperator.isBareRedirectOutWord(word[...]) == true)
    }

    @Test("bare redirect-out words reject non-targets", arguments: [
        ">&2", "2>&1", "1>&2", ">&1", ">&-", "<&-",
        "<", "<<", "<<<", "<<-", "<&",
        "", "2", "&", "x", ">>x", ">>>", "2>&1b",
    ])
    func bareWordRejects(word: String) {
        #expect(RedirectOperator.isBareRedirectOutWord(word[...]) == false)
    }

    @Test("fd-less >& matches both bare-word views (it starts with >)")
    func bareWordAmpersandDup() {
        #expect(RedirectOperator.isBareRedirectOutWord(">&"[...]) == true)
        #expect(RedirectOperator.isBareRedirectOutWord("2>&"[...]) == true)
        #expect(RedirectOperator.isRedirectOperatorWord(">&") == true)
    }

    @Test("bare redirect-out words reject quoted and dynamic words", arguments: [
        "'>'", "\">\"", "2\\>", "$X>", "`2>`", "$'>'",
    ])
    func bareWordRejectsQuotedDynamic(word: String) {
        #expect(RedirectOperator.isBareRedirectOutWord(word[...]) == false)
    }

    @Test("decoded-word view matches legacy operator table", arguments: [
        ">", ">>", ">|", ">&", "<>", "&>", "&>>",
        "2>", "10>>", "2>&",
    ])
    func operatorWordMatches(word: String) {
        #expect(RedirectOperator.isRedirectOperatorWord(word) == true)
    }

    @Test("decoded-word view rejects dups, closes, and inputs", arguments: [
        ">&2", "2>&1", ">&-", "<&-", "<", "<<", "<&", "", "2>&1b",
    ])
    func operatorWordRejects(word: String) {
        #expect(RedirectOperator.isRedirectOperatorWord(word) == false)
    }

    @Test("decoded-word view is grammar-identical to legacy isRedirectOperator")
    func operatorWordDifferentialMatchesLegacy() {
        let corpus = [
            "&>", "&>>", ">&", "<>", ">", ">>", ">|", "2>", "10>>", "2>&",
            ">&2", "2>&1", "1>&2", ">&-", "<&-", "<", "<<", "<<<", "<<-",
            "<&", "2>&1b", "", "2", "&", "x", ">&file", "2>file", "&>file",
            ">>>", "&>|", "0<", "2<", "a", ">|x", "10<>",
        ]
        for word in corpus {
            #expect(
                RedirectOperator.isRedirectOperatorWord(word) == isRedirectOperator(word),
                "divergence on \(word.debugDescription)"
            )
        }
    }

    @Test("raw words carrying unquoted > are structural", arguments: [
        "hi>", "hi>\"/tmp/eve\"", "2>&1", "a2>>b", ">", "a>b\"c\"",
    ])
    func rawWordCarries(word: String) {
        #expect(RedirectOperator.rawWordCarriesUnquotedRedirectOut(word[...]) == true)
    }

    @Test("fully quoted or escaped > stays data", arguments: [
        "\"a>b\"", "'a>b'", "$'a>b'", "a\\>b", "plain", "a<b", "",
    ])
    func rawWordStaysData(word: String) {
        #expect(RedirectOperator.rawWordCarriesUnquotedRedirectOut(word[...]) == false)
    }

    @Test("segment view splits at operator boundaries")
    func splitPieces() {
        #expect(RedirectOperator.splitRedirectPieces("b>/tmp/x") == ["b", ">", "/tmp/x"])
        #expect(RedirectOperator.splitRedirectPieces("a2>>b") == ["a", "2>>", "b"])
        #expect(RedirectOperator.splitRedirectPieces("a10>b") == ["a", "10>", "b"])
        #expect(RedirectOperator.splitRedirectPieces("a<>b") == ["a", "<>", "b"])
        #expect(RedirectOperator.splitRedirectPieces("a<<<b") == ["a", "<<<", "b"])
        #expect(RedirectOperator.splitRedirectPieces("a<<-EOF") == ["a", "<<-", "EOF"])
        #expect(RedirectOperator.splitRedirectPieces("plain") == ["plain"])
    }

    @Test("segment view glues dup/close targets, splits file tails")
    func splitPiecesDupClose() {
        #expect(RedirectOperator.splitRedirectPieces("2>&1") == ["2>&1"])
        #expect(RedirectOperator.splitRedirectPieces(">&-") == [">&-"])
        #expect(RedirectOperator.splitRedirectPieces("a<&-") == ["a", "<&-"])
        // `2>&1b` duplicates to the FILE `1b`, not fd 1 (spec §9 edge).
        #expect(RedirectOperator.splitRedirectPieces("2>&1b") == ["2>&", "1b"])
        #expect(RedirectOperator.splitRedirectPieces("a>&1b") == ["a", ">&", "1b"])
    }

    @Test("argv view matches redirect-led words", arguments: [
        ">", ">>x", "<foo", "&>f", ">&1", ":>x", "2>", "10>>x",
    ])
    func redirectTokenMatches(word: String) {
        #expect(RedirectOperator.isRedirectToken(word) == true)
    }

    @Test("argv view rejects non-redirect heads", arguments: [
        "2<", "x", "/bin/ls", "", "2", "-", "0x>",
    ])
    func redirectTokenRejects(word: String) {
        #expect(RedirectOperator.isRedirectToken(word) == false)
    }

    @Test("tokenizer target marking flows through the grammar module")
    func tokenizerTargetMarking() {
        let spaced = ShellPipeline.tokenize("echo hi > /tmp/x")
        #expect(spaced.last?.isRedirectStructural == true)
        // Dup operators with no glued target also take the next word.
        let dupBare = ShellPipeline.tokenize("echo hi >& /tmp/x")
        #expect(dupBare.last?.isRedirectStructural == true)
        let dupFd = ShellPipeline.tokenize("echo hi 2>& /tmp/x")
        #expect(dupFd.last?.isRedirectStructural == true)
        // A glued dup target takes no next word.
        let glued = ShellPipeline.tokenize("echo hi 2>&1 /tmp/x")
        #expect(glued.last?.isRedirectStructural == false)
    }
}
