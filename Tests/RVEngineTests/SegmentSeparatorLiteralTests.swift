import Testing
@testable import RVEngine

@Suite("Segment separator literal")
struct SegmentSeparatorLiteralTests {
    @Test(
        "literal separators outside classes count",
        arguments: [
            #"a\s*;\s*b"#, #"a&&b"#, #"a\s*\|\s*sh"#, #"a\;b"#, #"a\&b"#, #"a\nb"#, "a\nb",
            #"(?:&&|;|\|\|)"#, #"[^|;&]*(?:&&|;)"#, #"[^[:alnum:]_-];"#, #"\[;\]"#,
        ]
    )
    func namesSeparator(_ pattern: String) {
        #expect(patternNamesSegmentSeparator(pattern))
    }

    @Test(
        "alternation, classes and plain escapes do not count",
        arguments: [
            #"rm\s+.*--recursive.*--force|rm\s+.*--force.*--recursive"#,
            #"git\s+(?:[^\s&;|`()<>]+\s+)*push"#, #"[^|;&\n]*"#, #"[^[:alnum:]_-]git"#,
            #"a\\b"#, "",
        ]
    )
    func doesNotNameSeparator(_ pattern: String) {
        #expect(patternNamesSegmentSeparator(pattern) == false)
    }
}
