import Testing
import RVDomain

@Suite("Display")
struct DisplayTests {
    @Test func incompleteEvalSentence_isSharedHookAndTTYCopy() {
        #expect(incompleteEvalSentence == "rv could not finish evaluating this command. Run it in Terminal.")
    }

    @Test func fieldEscapesUnenumeratedBidiFormatAndControlScalars() {
        // Category-based: scalars no hand-written list named are escaped too.
        for raw in ["a\u{061C}b", "a\u{206A}b", "a\u{000E}b", "a\u{007F}b", "a\u{200F}b", "a\u{FEFF}b", "a\u{E0041}b", "a\tb", "a\u{0085}b"] {
            let shown = DisplayedText.field(raw)
            #expect(shown != raw, "\(raw.debugDescription) shown raw")
            #expect(shown.unicodeScalars.allSatisfy { DisplayedText.needsEscape($0) == false }, "\(shown.debugDescription)")
        }
        #expect(DisplayedText.field("plain text-1_ok") == "plain text-1_ok")
        #expect(DisplayedText.field("a\nb") == "a\\nb")
    }

    @Test func escapeJSONScalarsEscapesNELBidiAndAstralFormatScalars() {
        let json = "{\"s\":\"a\u{0085}b\u{202A}c\u{E0041}d\"}"
        let escaped = DisplayedText.escapeJSONScalars(json)
        #expect(escaped.contains("\\u0085"))
        #expect(escaped.contains("\\u202a"))
        #expect(escaped.contains("\\udb40\\udc41"))
        #expect(escaped.unicodeScalars.contains { $0.value == 0x85 } == false)
    }

    @Test func displayRuleID_usesSlashNotColon() throws {
        let rule = try #require(RuleID(rawValue: "core.git:reset-hard"))
        #expect(displayRuleID(rule) == "core.git/reset-hard")
        #expect(displayRuleID(rule) == rule.slashDisplay)
        #expect(displayRuleID(rule) != rule.rawValue)
    }
}
