import Testing
import RVDomain

/// K2 check words: the code's three bytes as three plain words, the same
/// in the terminal and on the menu bar's sheet.
struct CheckWordsTests {
    @Test func theListHas256DistinctPlainWords() {
        #expect(CheckWords.list.count == 256)
        #expect(Set(CheckWords.list).count == 256)
        #expect(CheckWords.list.allSatisfy { word in
            (3...7).contains(word.count) && word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
        })
    }

    @Test func eachByteIsOneWord() throws {
        let code = try #require(AllowOnceUnlockCode(validating: "a7c835"))
        #expect(CheckWords.words(for: code) == ["orchid", "rocket", "crane"])
        #expect(CheckWords.line(for: code) == "orchid · rocket · crane")
        #expect(CheckWords.words(for: try #require(AllowOnceUnlockCode(validating: "000000"))) == ["acorn", "acorn", "acorn"])
        #expect(CheckWords.words(for: try #require(AllowOnceUnlockCode(validating: "ff01fe"))) == ["lime", "agate", "wave"])
    }

    @Test func differentCodesReadDifferently() throws {
        var seen = Set<[String]>()
        for value in stride(from: 0, to: 0xFFFFFF, by: 4_099) {
            let hex = String(value, radix: 16)
            let code = try #require(AllowOnceUnlockCode(validating: String(repeating: "0", count: 6 - hex.count) + hex))
            #expect(seen.insert(CheckWords.words(for: code)).inserted)
        }
    }
}
