import Foundation
import Testing
@testable import RVMCP

@Suite("MCPRedaction classification")
struct MCPRedactionClassificationTests {
    let tail = "hp_1234567890abcdefghij"

    @Test func separatorsAreClassifiedByCategoryNotListedRanges() {
        // U+2619 is the first codepoint past the old hand-listed ranges;
        // emoji, enclosed numbers, and unassigned scalars separate too.
        for code: UInt32 in [0x2619, 0x1F600, 0x24EB, 0x2B1B] {
            let mark = String(Unicode.Scalar(code)!)
            #expect(MCPRedaction.credentialHidesAnotherSecret("ctx7sk-12345678g" + mark + tail), "U+\(String(code, radix: 16))")
            #expect(MCPRedaction.argumentCarriesRefusedSecret("g" + mark + tail), "U+\(String(code, radix: 16))")
        }
    }

    @Test func compatibilitySpellingsOfAPrefixStillReadAsThePrefix() {
        #expect(MCPRedaction.looksLikeToken("ｇｈｐ＿1234567890abcdefghij"))
        #expect(MCPRedaction.pathSegmentCarriesToken("ｇｈｐ＿1234567890abcdefghij"))
    }

    @Test func secretNamesSplitOnCamelCaseHumps() {
        for name in ["clientSecret", "accessToken", "privateKey", "oauth2Token", "APIKey", "PASS", "WEBHOOK_URL", "dbPassphrase"] {
            #expect(MCPRedaction.isSecretName(name), "\(name)")
        }
        for name in ["monkey", "keyboard", "author", "LOG_LEVEL", "region"] {
            #expect(MCPRedaction.isSecretName(name) == false, "\(name)")
        }
    }

    @Test func listMaskingCoversEqualsValuesAndBareCredentials() {
        let (shown, credentials) = MCPRedaction.args([
            "--database-url=postgres://user:pw@db.example/app",
            "--config=/opt/ghp_1234567890abcdefghij",
            "--pass=hunter2",
            ".ghp_1234567890abcdefghij",
            "--region=us-east-1",
        ])
        #expect(shown == [
            "--database-url=<redacted>", "--config=<redacted>", "--pass=<redacted>",
            "<redacted>", "--region=us-east-1",
        ])
        #expect(credentials == ["--database-url", "--config", "--pass", "argument 4"])
    }
}

extension MCPRedactionClassificationTests {
    @Test func rereviewMaskingGapsStayClosed() {
        #expect(MCPRedaction.isSecretName("TOKEN2"))
        #expect(MCPRedaction.isSecretName("apiKey2"))
        let (shown, _) = MCPRedaction.args([
            "-aghp_1234567890abcdefghij",
            "X-Api-Key: hunter2",
            #"{"password":"hunter2"}"#,
            "--verbose",
        ])
        #expect(shown == ["<redacted>", "<redacted>", "<redacted>", "--verbose"], "\(shown)")
    }
}
