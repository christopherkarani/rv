import Testing
import RVDomain

@Suite("Secrets redaction")
struct SecretsRedactionTests {
    @Test func urlStripsQueryValuesButKeepsNames() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/search?q=secret&lang=en")
                == "https://example.com/search?q=[redacted]&lang=[redacted]"
        )
    }

    @Test func urlStripsFragmentEntirely() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/docs#access_token=abc")
                == "https://example.com/docs"
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/a?x=1#frag?y=2")
                == "https://example.com/a?x=[redacted]"
        )
    }

    @Test func urlStripsUserinfoButKeepsHostPortPath() {
        #expect(
            ReviewSanitizer.redactURL("https://user:pass@example.com:8443/p?q=1")
                == "https://example.com:8443/p?q=[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https://token@example.com/")
                == "https://example.com/"
        )
    }

    @Test func urlKeepsBareFlagsEmptyPairsAndValuelessNames() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?debug&empty=&x=1")
                == "https://example.com/?debug&empty=[redacted]&x=[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?a=1&&b=2")
                == "https://example.com/?a=[redacted]&&b=[redacted]"
        )
        #expect(ReviewSanitizer.redactURL("https://example.com/?=x") == "https://example.com/?=[redacted]")
    }

    @Test func urlRedactsSecretShapedValuelessPairs() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?ghp_abc123")
                == "https://example.com/?[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?debug&x=1")
                == "https://example.com/?debug&x=[redacted]"
        )
    }

    @Test func urlWithoutQueryRoundTrips() {
        #expect(ReviewSanitizer.redactURL("https://example.com/a/b") == "https://example.com/a/b")
        #expect(ReviewSanitizer.redactURL("https://example.com") == "https://example.com")
        #expect(ReviewSanitizer.redactURL("https://example.com/path?") == "https://example.com/path?")
    }

    @Test func urlKeepsSchemeHostCaseAndIPv6Literals() {
        #expect(
            ReviewSanitizer.redactURL("HTTPS://Example.COM:443/a?B=c")
                == "HTTPS://Example.COM:443/a?B=[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https://[::1]:8080/a?t=1")
                == "https://[::1]:8080/a?t=[redacted]"
        )
    }

    @Test func urlSplitSmugglingLastAtSignWins() {
        #expect(
            ReviewSanitizer.redactURL("https://attacker@victim@example.com/")
                == "https://example.com/"
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/a@b?t=1")
                == "https://example.com/a@b?t=[redacted]"
        )
    }

    @Test func urlPercentEncodedValuesAreStillStripped() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?token=%67%68%70_%61%62%63&next=%2Fhome")
                == "https://example.com/?token=[redacted]&next=[redacted]"
        )
    }

    @Test func urlSemicolonSeparatorCannotLeakValues() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?a=1;b=secret")
                == "https://example.com/?a=[redacted]"
        )
    }

    @Test func urlNewlineSmugglingCannotInjectLabels() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?a=1\nX-Injected: yes&b=2")
                == "https://example.com/?a=[redacted]&b=[redacted]"
        )
    }

    @Test func urlUnicodeUserinfoStrippedAndUnicodePathKept() {
        #expect(
            ReviewSanitizer.redactURL("https://us\u{435}r:p\u{430}ss@example.com/")
                == "https://example.com/"
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/caf\u{E9}?a=1")
                == "https://example.com/caf\u{E9}?a=[redacted]"
        )
    }

    @Test func urlMissingSchemeFallsBackToCredentialScrub() {
        #expect(
            ReviewSanitizer.redactURL("example.com/?token=abc")
                == "example.com/?token=[redacted]"
        )
        #expect(ReviewSanitizer.redactURL("notaurl") == "notaurl")
    }

    @Test func urlEmptySchemeOrAuthorityFallsBackToCredentialScrub() {
        #expect(
            ReviewSanitizer.redactURL("://example.com/?token=abc")
                == "://example.com/?token=[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https:///path?token=abc")
                == "https:///path?token=[redacted]"
        )
        #expect(
            ReviewSanitizer.redactURL("https://@?token=abc")
                == "https://@?token=[redacted]"
        )
    }

    @Test func urlAtSizeCapStillRedactsStructurally() {
        let prefix = "https://example.com/"
        let suffix = "?token=secret"
        let padding = HTTPEgressLimits.maxURLUTF8Bytes - prefix.utf8.count - suffix.utf8.count
        let url = prefix + String(repeating: "a", count: padding) + suffix
        #expect(url.utf8.count == HTTPEgressLimits.maxURLUTF8Bytes)
        #expect(
            ReviewSanitizer.redactURL(url)
                == prefix + String(repeating: "a", count: padding) + "?token=[redacted]"
        )
    }

    @Test func overlongURLFailsClosed() {
        let url = "https://example.com/" + String(repeating: "a", count: HTTPEgressLimits.maxURLUTF8Bytes)
        #expect(ReviewSanitizer.redactURL(url) == ReviewSanitizer.redactedPlaceholder)
    }

    @Test func emptyURLStaysEmpty() {
        #expect(ReviewSanitizer.redactURL("") == "")
    }

    @Test func headersKeepSafeSetCaseInsensitively() {
        let redacted = ReviewSanitizer.redactHeaders([
            "Content-Type": "application/json",
            "CONTENT-LENGTH": "42",
            "Accept": "application/json",
            "accept-encoding": "gzip",
        ])
        #expect(redacted == [
            "Content-Type": "application/json",
            "CONTENT-LENGTH": "42",
            "Accept": "application/json",
            "accept-encoding": "gzip",
        ])
    }

    @Test func headersAlwaysRedactAuth() {
        let redacted = ReviewSanitizer.redactHeaders([
            "authorization": "Bearer ghp_secret",
            "Authorization": "Basic dXNlcjpwYXNz",
            "AUTHORIZATION": "token xyz",
            "Proxy-Authorization": "secret",
        ])
        #expect(redacted == [
            "authorization": "[redacted]",
            "Authorization": "[redacted]",
            "AUTHORIZATION": "[redacted]",
            "Proxy-Authorization": "[redacted]",
        ])
    }

    @Test func headersRedactEverythingOutsideTheSafeSet() {
        let redacted = ReviewSanitizer.redactHeaders([
            "Cookie": "session=abc",
            "Set-Cookie": "id=1",
            "X-Api-Key": "sk-secret",
            "User-Agent": "rv/1.0",
            "Host": "example.com",
        ])
        #expect(redacted == [
            "Cookie": "[redacted]",
            "Set-Cookie": "[redacted]",
            "X-Api-Key": "[redacted]",
            "User-Agent": "[redacted]",
            "Host": "[redacted]",
        ])
    }

    @Test func headersRejectConfusableAndPaddedSafeNames() {
        #expect(
            ReviewSanitizer.redactHeaders(["\u{441}ontent-type": "application/json"])
                == ["\u{441}ontent-type": "[redacted]"]
        )
        #expect(
            ReviewSanitizer.redactHeaders(["content-type\u{200B}": "application/json"])
                == ["content-type\u{200B}": "[redacted]"]
        )
        #expect(
            ReviewSanitizer.redactHeaders([" content-type": "application/json"])
                == [" content-type": "[redacted]"]
        )
    }

    @Test func headersEmptyStaysEmptyAndEmptyNameRedacted() {
        #expect(ReviewSanitizer.redactHeaders([:]) == [:])
        #expect(ReviewSanitizer.redactHeaders(["": "value"]) == ["": "[redacted]"])
    }

    @Test func analyticsAdmitsOnlyBooleansAndCounts() {
        #expect(ReviewSanitizer.isAnalyticsSafe(.bool(true)) == true)
        #expect(ReviewSanitizer.isAnalyticsSafe(.bool(false)) == true)
        #expect(ReviewSanitizer.isAnalyticsSafe(.int(0)) == true)
        #expect(ReviewSanitizer.isAnalyticsSafe(.int(-7)) == true)
        #expect(ReviewSanitizer.isAnalyticsSafe(.string("ok")) == false)
        #expect(ReviewSanitizer.isAnalyticsSafe(.string("")) == false)
        #expect(ReviewSanitizer.isAnalyticsSafe(.string("ghp_secret")) == false)
        #expect(ReviewSanitizer.isAnalyticsSafe(.strings(["a", "b"])) == false)
        #expect(ReviewSanitizer.isAnalyticsSafe(.strings([])) == false)
    }

    @Test func analyticsPropertiesRequireEveryValueSafe() {
        #expect(ReviewSanitizer.isAnalyticsSafe(properties: [:]) == true)
        #expect(
            ReviewSanitizer.isAnalyticsSafe(properties: ["enabled": .bool(true), "count": .int(3)]) == true
        )
        #expect(
            ReviewSanitizer.isAnalyticsSafe(properties: ["count": .int(3), "note": .string("ok")]) == false
        )
    }

    @Test func logScrubsSecretsButKeepsLabels() {
        #expect(
            ReviewSanitizer.redactLog("token=ghp_abcdef user=alice")
                == "token=[redacted] user=alice"
        )
    }

    @Test func logRedactsBearerFollowOnToken() {
        #expect(
            ReviewSanitizer.redactLog("Authorization: Bearer ghp_xyz")
                == "Authorization: Bearer [redacted]"
        )
    }

    @Test func logRedactsPEMBlocks() {
        #expect(
            ReviewSanitizer.redactLog("key: -----BEGIN PRIVATE KEY----- MIIEvQ")
                == ReviewSanitizer.redactedPlaceholder
        )
    }

    @Test func plainLogPassesThroughUntouched() {
        #expect(ReviewSanitizer.redactLog("dispatch ok attempt=3") == "dispatch ok attempt=3")
        #expect(ReviewSanitizer.redactLog("") == "")
    }

    @Test func overlongLogStillScrubbed() {
        let message = "start " + String(repeating: "x ", count: 50_000) + " password=hunter2"
        let redacted = ReviewSanitizer.redactLog(message)
        #expect(redacted.contains("[redacted]"))
        #expect(redacted.contains("hunter2") == false)
    }

    @Test func urlFragmentCutBeforeUserinfoFailsClosed() {
        #expect(
            ReviewSanitizer.redactURL("https://user:pa#ss@example.com/")
                == ReviewSanitizer.redactedPlaceholder
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?a=1#x@y")
                == "https://example.com/?a=[redacted]"
        )
    }

    @Test func urlControlCharactersInSchemeAuthorityOrPathFailClosed() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/a\nX: b?q=1")
                == ReviewSanitizer.redactedPlaceholder
        )
        #expect(
            ReviewSanitizer.redactURL("https://exam\nple.com/a?q=1")
                == ReviewSanitizer.redactedPlaceholder
        )
        #expect(
            ReviewSanitizer.redactURL("https://example.com/a?q=1")
                == "https://example.com/a?q=[redacted]"
        )
    }

    @Test func urlQueryPairWithMultipleEqualsKeepsNameOnly() {
        #expect(
            ReviewSanitizer.redactURL("https://example.com/?a=b=c")
                == "https://example.com/?a=[redacted]"
        )
    }

    @Test func urlSizeCapCountsMultibyteCharactersAsBytes() {
        let prefix = "https://example.com/"
        let suffix = "?token=secret"
        let room = HTTPEgressLimits.maxURLUTF8Bytes - prefix.utf8.count - suffix.utf8.count
        let exact = prefix + String(repeating: "a", count: room - 2) + "é" + suffix
        #expect(exact.utf8.count == HTTPEgressLimits.maxURLUTF8Bytes)
        #expect(
            ReviewSanitizer.redactURL(exact)
                == prefix + String(repeating: "a", count: room - 2) + "é" + "?token=[redacted]"
        )
        let over = prefix + String(repeating: "a", count: room - 1) + "é" + suffix
        #expect(over.utf8.count == HTTPEgressLimits.maxURLUTF8Bytes + 1)
        #expect(ReviewSanitizer.redactURL(over) == ReviewSanitizer.redactedPlaceholder)
    }

    @Test func urlMissingSchemeWithFragmentStillScrubsCredentialShapedPairs() {
        #expect(
            ReviewSanitizer.redactURL("example.com/d#access_token=abc")
                == "example.com/d#access_token=[redacted]"
        )
    }

    @Test func urlControlCharacterInQuerylessTailFailsClosed() {
        #expect(
            ReviewSanitizer.redactURL("https://host/pa\u{07}th")
                == ReviewSanitizer.redactedPlaceholder
        )
    }
}
