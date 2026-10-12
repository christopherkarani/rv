import Foundation
import Testing
@testable import RVAnalytics

// Oracle citations use Executor paths under `/tmp/rv-secrets-compare/executor`:
//   events.ts                  packages/core/analytics/src/events.ts
//   analytics.ts / .test.ts    packages/core/analytics/src/analytics.ts
//   engine.ts / engine.test.ts packages/core/analytics/src/engine.ts
//   redact.ts                  packages/core/sdk/src/telemetry-url-redaction.ts

// MARK: - Plugin keys (property rules: fixed vocabulary, slugs forbidden)

@Suite("MCPPluginKey")
struct MCPPluginKeyTests {
    @Test func acceptsKnownVocabulary() {
        for key in ["openapi", "mcp", "graphql", "http", "a", "x-9", "tool-2-cache"] {
            #expect(MCPPluginKey(key)?.rawValue == key)
        }
    }

    @Test func acceptsExactly64Bytes() {
        let key = String(repeating: "a", count: 64)
        #expect(MCPPluginKey(key)?.rawValue == key)
    }

    @Test func rejectsEmpty() {
        #expect(MCPPluginKey("") == nil)
    }

    @Test func rejectsOverlong() {
        #expect(MCPPluginKey(String(repeating: "a", count: 65)) == nil)
        #expect(MCPPluginKey(String(repeating: "ab-", count: 100)) == nil)
    }

    @Test func rejectsUppercase() {
        #expect(MCPPluginKey("OpenAPI") == nil)
        #expect(MCPPluginKey("MCP") == nil)
    }

    @Test func rejectsSlugShapes() {
        // Integration slugs / free text are outside the fixed vocabulary.
        for candidate in ["my.slug", "github-issues.create", "my slug", "my_slug", "a/b", "a:b", "a@b"] {
            #expect(MCPPluginKey(candidate) == nil)
        }
    }

    @Test func rejectsNoNormalization() {
        // Surrounding whitespace is rejected, never trimmed: fail closed.
        #expect(MCPPluginKey(" mcp") == nil)
        #expect(MCPPluginKey("mcp ") == nil)
        #expect(MCPPluginKey("\tmcp\n") == nil)
    }

    @Test func rejectsControlsAndSeparators() {
        // Controls and separators fall outside `[a-z0-9-]`, so the charset
        // subsumes the legibility rule with no second check.
        for candidate in ["openapi\nx", "a\rb", "a\u{0000}b", "a\u{007F}b", "a\u{2028}b", "a\u{2029}b"] {
            #expect(MCPPluginKey(candidate) == nil)
        }
    }

    @Test func rejectsInvisibleFormat() {
        for candidate in ["a\u{200B}b", "a\u{FEFF}b", "a\u{200E}b", "a\u{2066}b"] {
            #expect(MCPPluginKey(candidate) == nil)
        }
    }

    @Test func rejectsUnicodeLettersAndEmoji() {
        for candidate in ["café", "mcp🚀", "日本語", "Straße", "naïve-key"] {
            #expect(MCPPluginKey(candidate) == nil)
        }
    }

    @Test func rejectsTraversalAndGlobShapes() {
        for candidate in ["../..", "a*", "*", "a?b", "a[b]", "a{b}", "a$b", "a`b`", "a'b", "a\"b"] {
            #expect(MCPPluginKey(candidate) == nil)
        }
    }

    @Test func rejectsHyphenOnlyAndDigits() {
        // Shape-valid but degenerate; still vocabulary-shaped, so accepted:
        // the rule is charset + bounds, not a registry lookup.
        #expect(MCPPluginKey("-")?.rawValue == "-")
        #expect(MCPPluginKey("9")?.rawValue == "9")
        #expect(MCPPluginKey("-9-a-")?.rawValue == "-9-a-")
    }
}

// MARK: - Catalog names + properties (events.ts)

@Suite("MCPAnalyticsCatalog")
struct MCPAnalyticsCatalogTests {
    @Test func executionCompletedNameAndProperties() {
        let event = MCPAnalyticsEvent.executionCompleted(ok: true, plane: .mcp, toolkit: false)
        #expect(event.name == "execution_completed")
        #expect(event.properties == [
            "ok": .bool(true),
            "plane": .string("mcp"),
            "toolkit": .bool(false),
        ])
    }

    @Test func executionCompletedAPIVariant() {
        let event = MCPAnalyticsEvent.executionCompleted(ok: false, plane: .api, toolkit: true)
        #expect(event.name == "execution_completed")
        #expect(event.properties["ok"] == .bool(false))
        #expect(event.properties["plane"] == .string("api"))
        #expect(event.properties["toolkit"] == .bool(true))
    }

    @Test func integrationAddedNameAndProperties() throws {
        let key = try #require(MCPPluginKey("openapi"))
        let event = MCPAnalyticsEvent.integrationAdded(pluginKey: key)
        #expect(event.name == "integration_added")
        #expect(event.properties == ["plugin_key": .string("openapi")])
    }

    @Test func integrationRemovedNameAndProperties() throws {
        let key = try #require(MCPPluginKey("mcp"))
        let event = MCPAnalyticsEvent.integrationRemoved(pluginKey: key)
        #expect(event.name == "integration_removed")
        #expect(event.properties == ["plugin_key": .string("mcp")])
    }

    @Test func artifactCreatedNameAndProperties() {
        let event = MCPAnalyticsEvent.artifactCreated(via: .agent)
        #expect(event.name == "artifact_created")
        #expect(event.properties == ["via": .string("agent")])
    }

    @Test func artifactViewedNameAndProperties() {
        let event = MCPAnalyticsEvent.artifactViewed(via: .ui)
        #expect(event.name == "artifact_viewed")
        #expect(event.properties == ["via": .string("ui")])
    }

    @Test func artifactUpdatedNameAndProperties() {
        let event = MCPAnalyticsEvent.artifactUpdated(via: .agent)
        #expect(event.name == "artifact_updated")
        #expect(event.properties == ["via": .string("agent")])
    }

    @Test func artifactDeletedNameAndProperties() {
        let event = MCPAnalyticsEvent.artifactDeleted(via: .ui)
        #expect(event.name == "artifact_deleted")
        #expect(event.properties == ["via": .string("ui")])
    }
}

// MARK: - Property rules gate

@Suite("MCPAnalyticsPropertyRules")
struct MCPAnalyticsPropertyRulesTests {
    @Test func everyCatalogEventPasses() throws {
        let key = try #require(MCPPluginKey("graphql"))
        let events: [MCPAnalyticsEvent] = [
            .executionCompleted(ok: true, plane: .mcp, toolkit: false),
            .executionCompleted(ok: false, plane: .api, toolkit: true),
            .integrationAdded(pluginKey: key),
            .integrationRemoved(pluginKey: key),
            .artifactCreated(via: .agent),
            .artifactViewed(via: .ui),
            .artifactUpdated(via: .agent),
            .artifactDeleted(via: .ui),
        ]
        for event in events {
            #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(event.properties))
        }
    }

    @Test func sharedBatchKeysPass() {
        #expect(
            MCPAnalyticsPropertyRules.isCatalogPropertyBag([
                "ok": .bool(true),
                "surface": .string("cli"),
                "channel": .string("dev"),
                "app_version": .string("1.0.0"),
                "$process_person_profile": .bool(false),
            ])
        )
    }

    @Test func emptyBagPassesVacuously() {
        #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag([:]))
    }

    @Test func rejectsSecretKeys() {
        for key in ["secret", "token", "credential", "credentials", "password", "api_key", "auth"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag([key: .string("x")]) == false
            )
        }
    }

    @Test func rejectsCodeArgsAndResultsKeys() {
        for key in ["code", "args", "arguments", "result", "results", "output", "error", "body"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag([key: .string("x")]) == false
            )
        }
    }

    @Test func rejectsFreeTextAndIdentityKeys() {
        for key in [
            "connection", "connection_name", "tool_address", "slug",
            "email", "hostname", "org", "user", "command", "path",
        ] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag([key: .string("x")]) == false
            )
        }
    }

    @Test func rejectsCaseVariants() {
        #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(["OK": .bool(true)]) == false)
        #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(["Plane": .string("mcp")]) == false)
        #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag([" ok": .bool(true)]) == false)
    }

    @Test func oneRogueKeyFailsMixedBag() {
        #expect(
            MCPAnalyticsPropertyRules.isCatalogPropertyBag([
                "ok": .bool(true),
                "plane": .string("mcp"),
                "code": .string("print(1)"),
            ]) == false
        )
    }

    @Test func rejectsWrongTypedValues() {
        // A secret smuggled as an allowed key's mistyped value still fails.
        let bags: [[String: AnalyticsPropertyValue]] = [
            ["ok": .string("true")],
            ["ok": .int(1)],
            ["ok": .strings(["true"])],
            ["toolkit": .string("false")],
            ["toolkit": .int(0)],
            ["plane": .bool(true)],
            ["plane": .int(1)],
            ["via": .bool(false)],
            ["plugin_key": .bool(true)],
            ["plugin_key": .int(7)],
            ["surface": .bool(true)],
            ["channel": .int(1)],
            ["app_version": .bool(true)],
            ["app_version": .int(3)],
            ["$process_person_profile": .string("false")],
            ["$process_person_profile": .int(0)],
        ]
        for bag in bags {
            #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(bag) == false)
        }
    }

    @Test func rejectsSmuggledEnumValues() {
        // Closed vocabularies stay members: no exfiltration past the label.
        for value in ["MCP", "mcp ", " mcp", "mcp;evil", "", "http", "cli"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["plane": .string(value)]) == false
            )
        }
        for value in ["AGENT", "agent\nadmin", "console", "", "ui "] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["via": .string(value)]) == false
            )
        }
        for value in ["local", "CLI", "cli ", "", "selfhost\nx"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["surface": .string(value)]) == false
            )
        }
        for value in ["nightly", "Stable", "dev ", "", "stable\nchannel=x"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["channel": .string(value)]) == false
            )
        }
    }

    @Test func rejectsSmuggledPluginKeys() {
        // Plugin keys re-validate: slugs and payloads fail as values too.
        for value in ["My.Slug", "evil slug", "../x", "UPPER", "a_b", "", "mcp\ntoken=hunter2"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["plugin_key": .string(value)])
                    == false
            )
        }
        #expect(
            MCPAnalyticsPropertyRules.isCatalogPropertyBag(
                ["plugin_key": .string(String(repeating: "a", count: 65))]
            ) == false
        )
    }

    @Test func rejectsPersonProfileOptIn() {
        // Anonymous events only: `true` would materialize a person profile.
        #expect(
            MCPAnalyticsPropertyRules.isCatalogPropertyBag(["$process_person_profile": .bool(true)])
                == false
        )
    }

    @Test func rejectsSmuggledVersions() {
        for value in ["", "1.0\nINJECTED=x", "v1.0\u{7F}", "1.0\u{0000}", "1.0é"] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["app_version": .string(value)])
                    == false
            )
        }
        #expect(
            MCPAnalyticsPropertyRules.isCatalogPropertyBag(
                ["app_version": .string(String(repeating: "1", count: 65))]
            ) == false
        )
    }

    @Test func acceptsBoundaryVersions() {
        for value in ["1.2.3", "0.0.0", "1.6.10-dev", "dev", String(repeating: "1", count: 64)] {
            #expect(
                MCPAnalyticsPropertyRules.isCatalogPropertyBag(["app_version": .string(value)])
            )
        }
    }
}

// MARK: - URL redaction (redact.ts › redactUrlForTelemetry / redactUrlsInText)

@Suite("MCPAnalyticsURLRedaction")
struct MCPAnalyticsURLRedactionTests {
    @Test func cleanURLUnchanged() {
        // Oracle: "returns a clean URL unchanged" + "leaves a query-,
        // fragment-, and userinfo-free URL untouched".
        for clean in [
            "https://example.test/p",
            "https://example.test/",
            "https://example.test",
            "http://example.test:8080/a/b",
        ] {
            let redacted = MCPAnalyticsURLRedaction.redact(clean)
            #expect(redacted.url == clean)
            #expect(redacted.stripped == [])
        }
    }

    @Test func stripsQueryFragmentAndUserinfoTogether() {
        // Oracle: "strips query, fragment, and userinfo together".
        let redacted = MCPAnalyticsURLRedaction.redact("https://user:pass@example.test:8080/p?q=1#f")
        #expect(redacted.url == "https://example.test:8080/p")
        #expect(redacted.stripped == ["fragment", "q", "userinfo"])
    }

    @Test func stripsEveryQueryValueKeepsNames() {
        // Oracle: "strips every query value from url.full and url.query".
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/cb?code=abc&state=xyz")
        #expect(redacted.url == "https://example.test/cb")
        #expect(redacted.stripped == ["code", "state"])
    }

    @Test func dropsSecretUnderAnyParameterName() {
        // Oracle: "drops a secret riding under any parameter name — names are
        // never trusted".
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?owner=hunter2")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == ["owner"])
        #expect(redacted.url.contains("hunter2") == false)
    }

    @Test func dropsNestedReturnToWholesale() {
        // Oracle: "drops a nested returnTo value wholesale — code, state, and
        // userinfo included".
        let redacted = MCPAnalyticsURLRedaction.redact(
            "https://example.test/cb?returnTo=https%3A%2F%2Finner.test%2Fgo%3Fcode%3Dabc"
        )
        #expect(redacted.url == "https://example.test/cb")
        #expect(redacted.stripped == ["returnTo"])
        #expect(redacted.url.contains("abc") == false)
    }

    @Test func namelessSegmentReportsStar() {
        // Oracle: "reports a nameless query segment as *, never by its text".
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?supertokenvalue")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == ["*"])
    }

    @Test func clearsFragmentTokenParseable() {
        // Oracle: "clears a fragment-borne token from a parseable URL".
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p#access_token=xyz")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == ["fragment"])
        #expect(redacted.url.contains("xyz") == false)
    }

    @Test func clearsFragmentTokenMalformed() {
        // Oracle: "clears a fragment-borne token from a malformed URL".
        let redacted = MCPAnalyticsURLRedaction.redact("example.test/p#access_token=xyz")
        #expect(redacted.url == "example.test/p")
        #expect(redacted.stripped == ["fragment"])
    }

    @Test func atInFragmentIsNotUserinfo() {
        // Oracle: "does not treat an @ inside the fragment as userinfo".
        let parsed = MCPAnalyticsURLRedaction.redact("https://example.test/p#user@host")
        #expect(parsed.url == "https://example.test/p")
        #expect(parsed.stripped == ["fragment"])
        let malformed = MCPAnalyticsURLRedaction.redact("notaurl#frag@x")
        #expect(malformed.url == "notaurl")
        #expect(malformed.stripped == ["fragment"])
    }

    @Test func stripsUserinfo() {
        // Oracle: "strips userinfo from a URL attribute".
        let redacted = MCPAnalyticsURLRedaction.redact("https://u:p@example.test/p")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == ["userinfo"])
        let bare = MCPAnalyticsURLRedaction.redact("https://u@example.test/p")
        #expect(bare.url == "https://example.test/p")
        #expect(bare.stripped == ["userinfo"])
    }

    @Test func degradesUnparseable() {
        // Oracle: "degrades an unparseable URL attribute instead of passing
        // it through".
        let redacted = MCPAnalyticsURLRedaction.redact("http://exa mple.test/x?tok=secret#f")
        #expect(redacted.url == "http://exa mple.test/x")
        #expect(redacted.stripped == ["fragment", "tok"])
        #expect(redacted.url.contains("secret") == false)
    }

    @Test func dropsUserinfoPrefixFromUnparseablePaste() {
        // Oracle (telemetry-endpoint.test.ts): "drops a userinfo-looking
        // prefix from an unparseable paste". The paste is unparseable because
        // of the space in the host — that, not the prefix, selects the
        // textual arm.
        let redacted = MCPAnalyticsURLRedaction.redact(
            "http://svc-user:synthetic-userinfo-password@exa mple.test/mcp?token=synthetic-query-token"
        )
        #expect(redacted.url == "exa mple.test/mcp")
        #expect(redacted.stripped == ["token", "userinfo"])
        #expect(redacted.url.contains("synthetic-query-token") == false)
        #expect(redacted.url.contains("synthetic-userinfo-password") == false)
    }

    @Test func schemeLookingPrefixOverStripsSafely() {
        // Deliberate divergence, safe direction: WHATWG reads `user:` as a
        // scheme (`URL.canParse` is true, path `pass@notaurl`, stripped
        // `["q"]`), but without authority parsing the prefix is
        // indistinguishable from userinfo, so the textual arm over-strips.
        // Removal only — the password never survives.
        let redacted = MCPAnalyticsURLRedaction.redact("user:pass@notaurl?q=1")
        #expect(redacted.url == "notaurl")
        #expect(redacted.stripped == ["q", "userinfo"])
    }

    @Test func plainTextUnchanged() {
        #expect(MCPAnalyticsURLRedaction.redact("notaurl").url == "notaurl")
        #expect(MCPAnalyticsURLRedaction.redact("notaurl").stripped == [])
        #expect(MCPAnalyticsURLRedaction.redact("").url == "")
        #expect(MCPAnalyticsURLRedaction.redact("http://[::1").url == "http://[::1")
    }

    @Test func noSchemeWithQueryUsesTextualArm() {
        let redacted = MCPAnalyticsURLRedaction.redact("example.test/p?a=1")
        #expect(redacted.url == "example.test/p")
        #expect(redacted.stripped == ["a"])
    }

    @Test func schemeWithoutHostUsesTextualArm() {
        // Deliberate divergence, safe direction: WHATWG parses `mailto:` as
        // scheme:opaque-path with no userinfo (`stripped == ["subject"]`);
        // the textual arm over-strips. Removal only — no leak.
        let redacted = MCPAnalyticsURLRedaction.redact("mailto:a@b.test?subject=x")
        #expect(redacted.url == "b.test")
        #expect(redacted.stripped == ["subject", "userinfo"])
    }

    @Test func emptyQueryAndFragmentAreNotStrips() {
        // Mirrors WhatWG `search`/`hash` empty-string behavior: nothing to
        // remove, so the value passes through unchanged.
        let query = MCPAnalyticsURLRedaction.redact("https://example.test/p?")
        #expect(query.url == "https://example.test/p?")
        #expect(query.stripped == [])
        let fragment = MCPAnalyticsURLRedaction.redact("https://example.test/p#")
        #expect(fragment.url == "https://example.test/p#")
        #expect(fragment.stripped == [])
    }

    @Test func emptyQuerySegmentsSkipped() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?a=1&&b=2")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == ["a", "b"])
    }

    @Test func emptyParameterNameReported() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?=v")
        #expect(redacted.url == "https://example.test/p")
        #expect(redacted.stripped == [""])
    }

    @Test func duplicateNamesDeduped() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?a=1&a=2")
        #expect(redacted.stripped == ["a"])
    }

    @Test func equalsInValueKeepsFirstName() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test/p?a=b=c")
        #expect(redacted.stripped == ["a"])
    }

    @Test func encodedSeparatorsInValuesYieldNoPhantomNames() {
        // Names are read from the ENCODED query: decoding first would split
        // `%26`/`%3D` inside values into phantom names, surfacing value
        // bytes through the stripped-keys diagnostic. Oracle:
        // `redactUrlForTelemetry` reads `url.search` (raw).
        let encoded = MCPAnalyticsURLRedaction.redact("https://example.test/p?a=%26b%3Dc")
        #expect(encoded.url == "https://example.test/p")
        #expect(encoded.stripped == ["a"])
        let nested = MCPAnalyticsURLRedaction.redact(
            "https://example.test/login?returnTo=x%26y%3Dz&code=SECRET1"
        )
        #expect(nested.url == "https://example.test/login")
        #expect(nested.stripped == ["code", "returnTo"])
        #expect(nested.url.contains("SECRET1") == false)
    }

    @Test func queryBeforeFragmentBothReported() {
        let parsed = MCPAnalyticsURLRedaction.redact("https://example.test/p?a=1#f=2")
        #expect(parsed.url == "https://example.test/p")
        #expect(parsed.stripped == ["a", "fragment"])
        let malformed = MCPAnalyticsURLRedaction.redact("p?a=1#f=2")
        #expect(malformed.url == "p")
        #expect(malformed.stripped == ["a", "fragment"])
    }

    @Test func preservesPortAndEncodedPath() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test:9443/a%20b?q=1")
        #expect(redacted.url == "https://example.test:9443/a%20b")
    }

    @Test func preservesIPv6Brackets() {
        let redacted = MCPAnalyticsURLRedaction.redact("http://[::1]:8080/p?x=1")
        #expect(redacted.url == "http://[::1]:8080/p")
        #expect(redacted.stripped == ["x"])
    }

    @Test func preservesEmptyPath() {
        let redacted = MCPAnalyticsURLRedaction.redact("https://example.test?x=1")
        #expect(redacted.url == "https://example.test")
    }

    @Test func scrubsURLEmbeddedInFreeText() {
        // Oracle: "scrubs a URL embedded in a free-text attribute".
        let text = "Transport: boom (GET https://example.test/p?code=abc#t) after 3 tries"
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText(text)
                == "Transport: boom (GET https://example.test/p) after 3 tries"
        )
    }

    @Test func textWithoutURLsUnchanged() {
        #expect(MCPAnalyticsURLRedaction.redactURLsInText("nothing here") == "nothing here")
        #expect(MCPAnalyticsURLRedaction.redactURLsInText("") == "")
    }

    @Test func scrubsMultipleURLsInText() {
        // Oracle (redact.ts): "scrubs userinfo, query values, and fragments
        // from embedded URLs".
        let text = "from https://a.test/x?k=1 to http://u@p.test:9/y#z done"
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText(text)
                == "from https://a.test/x to http://p.test:9/y done"
        )
    }

    @Test func urlAtTextBoundaries() {
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText("https://a.test/x?k=1")
                == "https://a.test/x"
        )
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText("see https://a.test/x?k=1")
                == "see https://a.test/x"
        )
    }

    @Test func delimitersStopTheMatch() {
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText("\"https://a.test/x?k=1\"")
                == "\"https://a.test/x\""
        )
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText("<https://a.test/x?k=1>")
                == "<https://a.test/x>"
        )
    }

    @Test func customSchemeScrubbedInText() {
        #expect(
            MCPAnalyticsURLRedaction.redactURLsInText("open my+scheme.2://h.test/p?t=1 now")
                == "open my+scheme.2://h.test/p now"
        )
    }

    @Test func bracketedHostInTextIsLeftAlone() {
        // The in-text pattern stops at brackets (oracle-identical class), so
        // a bracketed URL is not recognized mid-sentence. Whole-value
        // `redact` is the path that scrubs it.
        let text = "see http://[::1]:8080/p?x=1 now"
        #expect(MCPAnalyticsURLRedaction.redactURLsInText(text) == text)
        #expect(MCPAnalyticsURLRedaction.redact("http://[::1]:8080/p?x=1").url == "http://[::1]:8080/p")
    }
}

// MARK: - Property-style redaction fuzz (deterministic seed)

private struct XorShift64: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }

    mutating func pick(_ options: [String]) -> String {
        options[Int(next() % UInt64(options.count))]
    }
}

@Suite("MCPAnalyticsRedactionFuzz")
struct MCPAnalyticsRedactionFuzzTests {
    @Test func fuzzURLsNeverEchoSecrets() {
        // Property: for every generated URL, the redacted output carries no
        // query value, no userinfo secret, no fragment, and no `?`/`#`
        // remainder; scheme/host/port/path survive byte-identical.
        var rng = XorShift64(state: 0x1234_5678_9ABC_DEF1)
        let secrets = ["SECRET1", "STATE2", "INNER9", "TOK3", "s3cret"]
        for _ in 0..<300 {
            let scheme = rng.pick(["https", "http"])
            let user = rng.pick(["", "alice", "alice:s3cret"])
            let host = rng.pick(["example.test", "hooks.test", "[::1]"])
            let port = rng.pick(["", ":8080"])
            let path = rng.pick(["", "/", "/p", "/p/q", "/a%20b"])
            let query = rng.pick([
                "",
                "code=SECRET1&state=STATE2",
                "token",
                "k=v",
                "a=1&a=2",
                "returnTo=INNER9",
                "=v",
                "x=1&&y=2",
                "a=%26b%3Dc",
                "returnTo=x%26y%3Dz",
            ])
            let fragment = rng.pick(["", "#frag", "#access_token=TOK3"])
            var raw = "\(scheme)://"
            if user.isEmpty == false {
                raw += "\(user)@"
            }
            raw += "\(host)\(port)\(path)"
            if query.isEmpty == false {
                raw += "?\(query)"
            }
            raw += fragment

            let redacted = MCPAnalyticsURLRedaction.redact(raw)
            #expect(redacted.url.contains("?") == false)
            #expect(redacted.url.contains("#") == false)
            for secret in secrets {
                #expect(redacted.url.contains(secret) == false)
            }
            #expect(redacted.stripped == redacted.stripped.sorted())
            #expect(redacted.stripped.contains("userinfo") == (user.isEmpty == false))
            #expect(redacted.stripped.contains("fragment") == (fragment.isEmpty == false))
            if redacted.stripped.isEmpty {
                #expect(redacted.url == raw)
            } else {
                #expect(redacted.url == "\(scheme)://\(host)\(port)\(path)")
            }
            for name in redacted.stripped where name != "userinfo" && name != "fragment" {
                #expect(name == "*" || query.contains("\(name)=") || query == name || name.isEmpty)
            }

            let text = "oops (GET \(raw)) failed"
            let scrubbed = MCPAnalyticsURLRedaction.redactURLsInText(text)
            if host.hasPrefix("[") {
                // Bracketed hosts never fully match the URL-in-text pattern —
                // the character class is oracle-identical, so this boundary
                // is too. Whole-value `redact` above still scrubs them.
                if user.isEmpty {
                    #expect(scrubbed == text)
                } else {
                    // Only the `scheme://user@` prefix matches; the userinfo
                    // secret is stripped either way, while the bracketed
                    // remainder (and any query secret) passes through.
                    #expect(scrubbed.contains("s3cret") == false)
                    #expect(scrubbed.contains("?") == (query.isEmpty == false))
                }
            } else {
                for secret in secrets {
                    #expect(scrubbed.contains(secret) == false)
                }
                #expect(scrubbed.hasPrefix("oops (GET "))
                #expect(scrubbed.hasSuffix(") failed"))
            }
        }
    }

    @Test func fuzzPluginKeysMatchVocabulary() throws {
        // Property: acceptance is exactly `^[a-z0-9-]{1,64}\z` (ASCII-only
        // alphabet, so bytes == characters; `\z` is absolute end, since
        // `$` would forgive a trailing newline the key rejects).
        let pattern = try #require(
            try? NSRegularExpression(pattern: "^[a-z0-9-]{1,64}\\z")
        )
        let alphabet = Array("abz09- AZ_./:@*\n\u{0000}é🚀")
        var rng = XorShift64(state: 0xDEAD_BEEF_CAFE_1234)
        for _ in 0..<2000 {
            let length = Int(rng.next() % 70)
            var candidate = ""
            for _ in 0..<length {
                candidate.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
            }
            let range = NSRange(candidate.startIndex..., in: candidate)
            let expected = pattern.firstMatch(in: candidate, range: range) != nil
            #expect((MCPPluginKey(candidate) != nil) == expected)
        }
    }
}

// MARK: - Opt-out (analytics.test.ts › isAnalyticsDisabled)

@Suite("MCPAnalyticsDisabled")
struct MCPAnalyticsDisabledTests {
    @Test func emptyEnvironmentIsEnabled() {
        #expect(MCPAnalyticsDisabled.isDisabled(environment: [:]) == false)
    }

    @Test func unrelatedVariablesAreIgnored() {
        #expect(
            MCPAnalyticsDisabled.isDisabled(environment: ["HOME": "/x", "PATH": "/bin"]) == false
        )
    }

    @Test func doNotTrackTruthySpellings() {
        // Oracle: "honors DO_NOT_TRACK and EXECUTOR_DISABLE_ANALYTICS".
        for value in ["1", "true", "TRUE", "True", "yes", "YES", " Yes ", "\t1\n"] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": value])
            )
        }
    }

    @Test func doNotTrackFalsySpellings() {
        for value in ["0", "false", "FALSE", "no", "NO", "", "2", "on", "track"] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": value]) == false
            )
        }
    }

    @Test func executorFlagTruthySpellings() {
        for value in ["1", "true", "yes", "YES", " true "] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["EXECUTOR_DISABLE_ANALYTICS": value])
            )
        }
    }

    @Test func executorFlagFalsySpellings() {
        for value in ["0", "false", "no", "", "disable"] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(
                    environment: ["EXECUTOR_DISABLE_ANALYTICS": value]
                ) == false
            )
        }
    }

    @Test func eitherFlagDisables() {
        #expect(
            MCPAnalyticsDisabled.isDisabled(environment: [
                "DO_NOT_TRACK": "0",
                "EXECUTOR_DISABLE_ANALYTICS": "yes",
            ])
        )
        #expect(
            MCPAnalyticsDisabled.isDisabled(environment: [
                "DO_NOT_TRACK": "1",
                "EXECUTOR_DISABLE_ANALYTICS": "0",
            ])
        )
    }

    @Test func bothFalsyStaysEnabled() {
        #expect(
            MCPAnalyticsDisabled.isDisabled(environment: [
                "DO_NOT_TRACK": "0",
                "EXECUTOR_DISABLE_ANALYTICS": "false",
            ]) == false
        )
    }

    @Test func trimMatchesJSWhitespaceExactly() {
        // Oracle: `analytics.ts` › `truthy` uses `value.trim()`. U+0085 is
        // NOT trimmed by JS; U+FEFF IS — `.whitespacesAndNewlines` gets both
        // backwards, and the FEFF half would ignore a BOM-prefixed opt-out
        // the Executor honors.
        for value in ["1", "true", "yes"] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\u{85}\(value)"])
                    == false
            )
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\(value)\u{85}"])
                    == false
            )
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\u{FEFF}\(value)"])
            )
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\(value)\u{FEFF}"])
            )
        }
    }

    @Test func trimAgreesWithJSOnCommonSpaces() {
        // Representatives where Foundation and JS agree (regression net); NUL
        // is trimmed by neither. Escapes, in order: VT FF NBSP 2000 LS PS 202F
        // 205F 3000 1680.
        for pad in ["\u{B}", "\u{C}", "\u{A0}", "\u{2000}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{1680}"] {
            #expect(
                MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\(pad)1\(pad)"])
            )
        }
        #expect(MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "\u{0}1"]) == false)
        #expect(MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "1\u{0}"]) == false)
    }

    @Test func defaultEnvironmentMatchesExplicit() {
        let live = ProcessInfo.processInfo.environment
        #expect(
            MCPAnalyticsDisabled.isDisabled()
                == MCPAnalyticsDisabled.isDisabled(environment: live)
        )
    }
}

// MARK: - Buffering (analytics.ts › Analytics service)

private actor BatchRecorder {
    private(set) var batches: [MCPAnalyticsBatch] = []
    private var failNext = 0

    func setFailNext(_ count: Int) {
        failNext = count
    }

    func send(_ batch: MCPAnalyticsBatch) -> Bool {
        batches.append(batch)
        if failNext > 0 {
            failNext -= 1
            return false
        }
        return true
    }
}

private func makeBuffer(
    distinctID: String = "test-id",
    surface: MCPAnalyticsSurface = .cli,
    channel: MCPAnalyticsChannel = .dev,
    version: String = "0.0.0",
    disabled: Bool = false,
    recorder: BatchRecorder,
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_767_225_600) }
) -> MCPAnalyticsBuffer {
    MCPAnalyticsBuffer(
        distinctID: distinctID,
        surface: surface,
        channel: channel,
        version: version,
        disabled: disabled,
        sender: { batch in await recorder.send(batch) },
        now: now
    )
}

private actor SinkRecorder {
    private(set) var payloads: [AnalyticsPayload] = []
    private var fail = false

    func setFail(_ fail: Bool) {
        self.fail = fail
    }

    func capture(_ payload: AnalyticsPayload) -> AnalyticsDelivery {
        payloads.append(payload)
        return fail ? .dropped : .accepted
    }
}

private struct FakeSink: AnalyticsSink {
    let recorder: SinkRecorder

    func capture(_ payload: AnalyticsPayload) async -> AnalyticsDelivery {
        await recorder.capture(payload)
    }
}

@Suite("MCPAnalyticsBuffer")
struct MCPAnalyticsBufferTests {
    @Test func flushesBatchWithSharedProperties() async throws {
        // Oracle: "buffers events and flushes a PostHog batch with shared
        // properties".
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.record(.executionCompleted(ok: true, plane: .mcp, toolkit: false))
        let key = try #require(MCPPluginKey("openapi"))
        await buffer.record(.integrationAdded(pluginKey: key))
        #expect(await buffer.pendingCount == 2)
        await buffer.flush()
        #expect(await buffer.pendingCount == 0)
        let batches = await recorder.batches
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.distinctID == "test-id")
        #expect(batch.events.map(\.event) == ["execution_completed", "integration_added"])
        for event in batch.events {
            #expect(event.properties["$process_person_profile"] == .bool(false))
            #expect(event.properties["surface"] == .string("cli"))
            #expect(event.properties["channel"] == .string("dev"))
            #expect(event.properties["app_version"] == .string("0.0.0"))
            #expect(event.timestamp.isEmpty == false)
            #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(event.properties))
        }
        #expect(batch.events[0].properties["ok"] == .bool(true))
        #expect(batch.events[0].properties["plane"] == .string("mcp"))
        #expect(batch.events[0].properties["toolkit"] == .bool(false))
        #expect(batch.events[1].properties["plugin_key"] == .string("openapi"))
    }

    @Test func timestampsComeFromInjectedClock() async {
        let recorder = BatchRecorder()
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let buffer = makeBuffer(recorder: recorder, now: { moment })
        await buffer.record(.artifactViewed(via: .ui))
        await buffer.flush()
        let batches = await recorder.batches
        let stamp = batches.first?.events.first?.timestamp ?? ""
        #expect(ISO8601DateFormatter().date(from: stamp) == moment)
    }

    @Test func distinctIDStableAcrossFlushes() async {
        // Oracle: "mints the anonymous id once and reuses it across runtimes"
        // (minting is `AnalyticsIdentity`; the buffer reuses its id).
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.record(.artifactDeleted(via: .ui))
        await buffer.flush()
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.distinctID == "test-id" })
    }

    @Test func emptyFlushNeverDials() async {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.flush()
        #expect(await recorder.batches.count == 0)
    }

    @Test func splitsIntoBatchesOfFiftyInOrder() async throws {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        for index in 0..<55 {
            let key = try #require(MCPPluginKey("k\(index)"))
            await buffer.record(.integrationAdded(pluginKey: key))
        }
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 2)
        #expect(batches[0].events.count == 50)
        #expect(batches[1].events.count == 5)
        let keys = batches.flatMap { $0.events }.compactMap { $0.properties["plugin_key"] }
        #expect(keys == (0..<55).map { .string("k\($0)") })
    }

    @Test func exactlyFiftyIsOneBatch() async throws {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        for index in 0..<50 {
            let key = try #require(MCPPluginKey("k\(index)"))
            await buffer.record(.integrationAdded(pluginKey: key))
        }
        await buffer.flush()
        #expect(await recorder.batches.count == 1)
    }

    @Test func capDropsOldestFirst() async throws {
        // Oracle: `MAX_BUFFERED_EVENTS` — "a dead network must not grow
        // memory forever".
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        for index in 0..<505 {
            let key = try #require(MCPPluginKey("k\(index)"))
            await buffer.record(.integrationAdded(pluginKey: key))
        }
        #expect(await buffer.pendingCount == 500)
        await buffer.flush()
        let batches = await recorder.batches
        let keys = batches.flatMap { $0.events }.compactMap { $0.properties["plugin_key"] }
        #expect(keys.count == 500)
        #expect(keys.first == .string("k5"))
        #expect(keys.last == .string("k504"))
    }

    @Test func requeuesFailedBatchAndRetries() async {
        // Oracle: "re-queues the batch when delivery fails and never surfaces
        // the error".
        let recorder = BatchRecorder()
        await recorder.setFailNext(1)
        let buffer = makeBuffer(recorder: recorder)
        await buffer.record(.executionCompleted(ok: false, plane: .mcp, toolkit: true))
        await buffer.flush()
        #expect(await recorder.batches.count == 1)
        #expect(await buffer.pendingCount == 1)
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 2)
        #expect(batches[1].events.first?.event == "execution_completed")
        #expect(batches[1].events.first?.properties["toolkit"] == .bool(true))
        #expect(await buffer.pendingCount == 0)
    }

    @Test func failedBatchStopsDrainingAndKeepsOrder() async throws {
        let recorder = BatchRecorder()
        await recorder.setFailNext(100)
        let buffer = makeBuffer(recorder: recorder)
        for index in 0..<55 {
            let key = try #require(MCPPluginKey("k\(index)"))
            await buffer.record(.integrationAdded(pluginKey: key))
        }
        await buffer.flush()
        // The endpoint is unreachable: only the first batch was attempted,
        // and it went back to the front.
        #expect(await recorder.batches.count == 1)
        #expect(await buffer.pendingCount == 55)
        await recorder.setFailNext(0)
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 3)
        let retried = batches.dropFirst().flatMap { $0.events }
        let keys = retried.compactMap { $0.properties["plugin_key"] }
        #expect(keys == (0..<55).map { .string("k\($0)") })
    }

    @Test func recordsWhileFailedBatchWaits() async {
        let recorder = BatchRecorder()
        await recorder.setFailNext(1)
        let buffer = makeBuffer(recorder: recorder)
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.flush()
        await buffer.record(.artifactViewed(via: .agent))
        #expect(await buffer.pendingCount == 2)
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 2)
        #expect(batches[1].events.map(\.event) == ["artifact_created", "artifact_viewed"])
    }

    @Test func disabledNeverDialsOrBuffers() async {
        // Oracle: "disabled config produces a no-op service that never dials
        // out".
        let recorder = BatchRecorder()
        let buffer = makeBuffer(disabled: true, recorder: recorder)
        await buffer.record(.executionCompleted(ok: true, plane: .api, toolkit: false))
        await buffer.record(.artifactDeleted(via: .ui))
        #expect(await buffer.pendingCount == 0)
        await buffer.flush()
        #expect(await recorder.batches.count == 0)
    }

    @Test func concurrentRecordStormStaysBounded() async {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<20 {
                group.addTask {
                    for index in 0..<100 {
                        if let key = MCPPluginKey("w\(worker)-k\(index)") {
                            await buffer.record(.integrationAdded(pluginKey: key))
                        }
                    }
                }
            }
        }
        #expect(await buffer.pendingCount == 500)
        await buffer.flush()
        let delivered = await recorder.batches.flatMap { $0.events }
        #expect(delivered.count == 500)
        #expect(await buffer.pendingCount == 0)
    }

    @Test func allCatalogEventsFlushInsideVocabulary() async throws {
        let key = try #require(MCPPluginKey("mcp"))
        let recorder = BatchRecorder()
        let buffer = makeBuffer(
            distinctID: "anon-7",
            surface: .selfhost,
            channel: .stable,
            version: "1.2.3",
            recorder: recorder
        )
        await buffer.record(.executionCompleted(ok: true, plane: .api, toolkit: true))
        await buffer.record(.integrationAdded(pluginKey: key))
        await buffer.record(.integrationRemoved(pluginKey: key))
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.record(.artifactViewed(via: .ui))
        await buffer.record(.artifactUpdated(via: .agent))
        await buffer.record(.artifactDeleted(via: .ui))
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 1)
        let events = batches.first?.events ?? []
        #expect(events.count == 7)
        for event in events {
            #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(event.properties))
            #expect(event.properties["surface"] == .string("selfhost"))
            #expect(event.properties["channel"] == .string("stable"))
            #expect(event.properties["app_version"] == .string("1.2.3"))
        }
    }

    @Test func defaultClockRecordsParseableTimestamps() async {
        let recorder = BatchRecorder()
        let before = Date()
        let buffer = MCPAnalyticsBuffer(
            distinctID: "clock-default",
            surface: .cli,
            channel: .dev,
            version: "0.0.0",
            sender: { batch in await recorder.send(batch) }
        )
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.flush()
        let batches = await recorder.batches
        #expect(batches.count == 1)
        let stamp = batches.first?.events.first?.timestamp ?? ""
        let parsed = ISO8601DateFormatter().date(from: stamp)
        #expect(parsed != nil)
        #expect((parsed ?? .distantPast) >= before.addingTimeInterval(-5))
        #expect((parsed ?? .distantFuture) <= Date().addingTimeInterval(5))
    }

    @Test func unicodeAndHostileKeysNeverEnterBatch() async {
        // Hostile plugin keys fail validation, so hostile bytes can only
        // reach the buffer as fixed-vocabulary events — never as text.
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        let hostiles = [
            "x\nDROP", "a\u{0000}b", "é", "a b", "A", "a.b",
            String(repeating: "z", count: 65),
        ]
        for hostile in hostiles {
            #expect(MCPPluginKey(hostile) == nil)
        }
        await buffer.record(.executionCompleted(ok: true, plane: .mcp, toolkit: false))
        await buffer.flush()
        let events = await recorder.batches.first?.events ?? []
        #expect(events.count == 1)
        for event in events {
            for value in event.properties.values {
                if case .string(let text) = value {
                    #expect(text.contains("\n") == false)
                    #expect(text.contains("\u{0}") == false)
                }
            }
        }
    }

    @Test func envOptOutWiringSuppressesBuffer() async {
        // The composition-root recipe: `disabled` comes from the environment.
        // Oracle: `analytics.ts` › `config.disabled ?? isAnalyticsDisabled()`.
        let optedOut = makeBuffer(
            disabled: MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "1"]),
            recorder: BatchRecorder()
        )
        await optedOut.record(.executionCompleted(ok: true, plane: .mcp, toolkit: false))
        await optedOut.flush()
        #expect(await optedOut.pendingCount == 0)

        let recorder = BatchRecorder()
        let optedIn = makeBuffer(
            disabled: MCPAnalyticsDisabled.isDisabled(environment: ["DO_NOT_TRACK": "0"]),
            recorder: recorder
        )
        await optedIn.record(.executionCompleted(ok: true, plane: .mcp, toolkit: false))
        await optedIn.flush()
        #expect(await recorder.batches.count == 1)
    }

    @Test func sinkInitDeliversThroughExistingSink() async throws {
        let recorder = SinkRecorder()
        let buffer = MCPAnalyticsBuffer(
            distinctID: "sink-id",
            surface: .selfhost,
            channel: .stable,
            version: "1.2.3",
            sink: FakeSink(recorder: recorder)
        )
        await buffer.record(.executionCompleted(ok: true, plane: .api, toolkit: true))
        let key = try #require(MCPPluginKey("mcp"))
        await buffer.record(.integrationAdded(pluginKey: key))
        await buffer.flush()
        let payloads = await recorder.payloads
        #expect(payloads.count == 2)
        #expect(payloads.map(\.event) == ["execution_completed", "integration_added"])
        #expect(payloads.allSatisfy { $0.distinctID == "sink-id" })
        for payload in payloads {
            #expect(payload.properties["$process_person_profile"] == .bool(false))
            #expect(payload.properties["surface"] == .string("selfhost"))
            #expect(payload.properties["channel"] == .string("stable"))
            #expect(payload.properties["app_version"] == .string("1.2.3"))
            #expect(MCPAnalyticsPropertyRules.isCatalogPropertyBag(payload.properties))
        }
        #expect(payloads.first?.properties["plane"] == .string("api"))
        #expect(payloads.last?.properties["plugin_key"] == .string("mcp"))
    }

    @Test func sinkInitFailureRequeuesWholeBatch() async {
        let recorder = SinkRecorder()
        await recorder.setFail(true)
        let buffer = MCPAnalyticsBuffer(
            distinctID: "sink-id",
            surface: .cli,
            channel: .dev,
            version: "0.0.0",
            sink: FakeSink(recorder: recorder)
        )
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.record(.artifactViewed(via: .agent))
        await buffer.flush()
        #expect(await recorder.payloads.count == 2)
        #expect(await buffer.pendingCount == 2)
        await recorder.setFail(false)
        await buffer.flush()
        #expect(await recorder.payloads.count == 4)
        #expect(await buffer.pendingCount == 0)
    }

    @Test func sinkInitDisabledNeverCaptures() async {
        let recorder = SinkRecorder()
        let buffer = MCPAnalyticsBuffer(
            distinctID: "sink-id",
            surface: .cli,
            channel: .dev,
            version: "0.0.0",
            disabled: true,
            sink: FakeSink(recorder: recorder)
        )
        await buffer.record(.artifactDeleted(via: .ui))
        await buffer.flush()
        #expect(await recorder.payloads.count == 0)
        #expect(await buffer.pendingCount == 0)
    }

    @Test func cadenceDefaultIsThirtySeconds() {
        // Oracle: `analytics.ts` › `flushInterval` default.
        #expect(MCPAnalyticsBuffer.flushCadenceSeconds == 30)
    }

    @Test func cadenceFlushesAutomatically() async {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 0.02)
        await buffer.record(.artifactCreated(via: .agent))
        var delivered = 0
        for _ in 0..<500 {
            let batches = await recorder.batches
            delivered = batches.flatMap(\.events).count
            if delivered == 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await buffer.stopCadence()
        #expect(delivered == 1)
        #expect(await buffer.pendingCount == 0)
    }

    @Test func cadenceStopPreventsDelivery() async {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 3600)
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.stopCadence()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.batches.count == 0)
        #expect(await buffer.pendingCount == 1)
    }

    @Test func cadenceRestartReplacesSchedule() async {
        // Idempotent restart: the first schedule is cancelled and stopping
        // still ends delivery.
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 3600)
        await buffer.startCadence(every: 3600)
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.stopCadence()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.batches.count == 0)
        #expect(await buffer.pendingCount == 1)
    }

    @Test func cadenceInvalidIntervalNeverStarts() async {
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 0)
        await buffer.startCadence(every: -5)
        await buffer.record(.artifactCreated(via: .agent))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.batches.count == 0)
        #expect(await buffer.pendingCount == 1)
        await buffer.stopCadence()
    }

    @Test func cadenceClampsExtremeIntervals() async {
        // A huge interval sleeps instead of trapping the `UInt64`
        // conversion; a tiny one still yields and flushes.
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 1e15)
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.stopCadence()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.batches.count == 0)
        #expect(await buffer.pendingCount == 1)

        await buffer.startCadence(every: 1e-9)
        var delivered = 0
        for _ in 0..<500 {
            let batches = await recorder.batches
            delivered = batches.flatMap(\.events).count
            if delivered == 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await buffer.stopCadence()
        #expect(delivered == 1)
    }

    @Test func cadenceDoesNotRetainBuffer() async {
        weak var weakBuffer: MCPAnalyticsBuffer?
        let recorder = BatchRecorder()
        do {
            let buffer = makeBuffer(recorder: recorder)
            weakBuffer = buffer
            await buffer.startCadence(every: 0.01)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(weakBuffer == nil)
    }

    @Test func shutdownStopsCadenceAndDrains() async {
        // Oracle: `analytics.ts` › `Effect.addFinalizer(() => flush)`.
        let recorder = BatchRecorder()
        let buffer = makeBuffer(recorder: recorder)
        await buffer.startCadence(every: 3600)
        await buffer.record(.artifactCreated(via: .agent))
        await buffer.record(.artifactViewed(via: .agent))
        await buffer.shutdown()
        let batches = await recorder.batches
        #expect(batches.count == 1)
        #expect(batches.first?.events.count == 2)
        #expect(await buffer.pendingCount == 0)
        // The cadence is stopped: nothing further flushes on its own.
        await buffer.record(.artifactDeleted(via: .ui))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await recorder.batches.count == 1)
        #expect(await buffer.pendingCount == 1)
    }
}

// MARK: - Invoke-path wrapper (engine.ts › withExecutionAnalytics)

private struct WrapperBoom: Error, Equatable, Sendable {}

private actor EventRecorder {
    private(set) var events: [MCPAnalyticsEvent] = []

    func record(_ event: MCPAnalyticsEvent) {
        events.append(event)
    }
}

private func makeWrapper(
    plane: MCPExecutionPlane = .mcp,
    toolkit: Bool = false,
    recorder: EventRecorder
) -> MCPAnalyticsInvokeWrapper {
    MCPAnalyticsInvokeWrapper(
        context: MCPExecutionContext(plane: plane, toolkit: toolkit),
        recorder: { event in await recorder.record(event) }
    )
}

@Suite("MCPAnalyticsInvokeWrapper")
struct MCPAnalyticsInvokeWrapperTests {
    @Test func callRecordsOk() async throws {
        // Oracle: "records ok on a completed execution".
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        let value = try await wrapper.recordCall(operation: { "ok" }, succeeded: { $0 == "ok" })
        #expect(value == "ok")
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .mcp, toolkit: false)
        ])
    }

    @Test func callRecordsNotOkValue() async throws {
        // Oracle: "records not-ok when the sandbox reports an error value".
        let recorder = EventRecorder()
        let wrapper = makeWrapper(plane: .api, recorder: recorder)
        let value = try await wrapper.recordCall(operation: { 7 }, succeeded: { $0 > 10 })
        #expect(value == 7)
        #expect(await recorder.events == [
            .executionCompleted(ok: false, plane: .api, toolkit: false)
        ])
    }

    @Test func callRecordsNotOkAndRethrows() async {
        // Oracle: "records not-ok when the engine fails on the error channel".
        let recorder = EventRecorder()
        let wrapper = makeWrapper(toolkit: true, recorder: recorder)
        await #expect(throws: WrapperBoom()) {
            try await wrapper.recordCall(operation: { throw WrapperBoom() }, succeeded: { _ in true })
        }
        #expect(await recorder.events == [
            .executionCompleted(ok: false, plane: .mcp, toolkit: true)
        ])
    }

    @Test func resumableCompletedRecordsOnce() async throws {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        let outcome = try await wrapper.recordResumable(operation: { .completed(ok: true) })
        #expect(outcome == .completed(ok: true))
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .mcp, toolkit: false)
        ])
    }

    @Test func resumableFailedCompletionRecordsNotOk() async throws {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        let outcome = try await wrapper.recordResumable(operation: { .completed(ok: false) })
        #expect(outcome == .completed(ok: false))
        #expect(await recorder.events == [
            .executionCompleted(ok: false, plane: .mcp, toolkit: false)
        ])
    }

    @Test func pauseRecordsNothingResumeCompletesOnce() async throws {
        // Oracle: "does not record a pause; records when the resume
        // completes".
        let recorder = EventRecorder()
        let paused = makeWrapper(recorder: recorder)
        let pause = try await paused.recordResumable(operation: { .paused })
        #expect(pause == .paused)
        #expect(await recorder.events == [])
        let resumed = makeWrapper(recorder: recorder)
        let done = try await resumed.recordResumable(operation: { .completed(ok: true) })
        #expect(done == .completed(ok: true))
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .mcp, toolkit: false)
        ])
    }

    @Test func unknownExecutionRecordsNothing() async throws {
        // Oracle: "resume of an unknown execution records nothing".
        let recorder = EventRecorder()
        let wrapper = makeWrapper(plane: .api, recorder: recorder)
        let outcome = try await wrapper.recordResumable(operation: { nil })
        #expect(outcome == nil)
        #expect(await recorder.events == [])
    }

    @Test func resumableThrowRecordsNotOkAndRethrows() async {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        await #expect(throws: WrapperBoom()) {
            try await wrapper.recordResumable(operation: { throw WrapperBoom() })
        }
        #expect(await recorder.events == [
            .executionCompleted(ok: false, plane: .mcp, toolkit: false)
        ])
    }

    @Test func labelsAreBoundStructurally() async throws {
        // Oracle: engine.ts header — "the wrap point IS the plane".
        let recorder = EventRecorder()
        let mcp = makeWrapper(plane: .mcp, toolkit: true, recorder: recorder)
        let api = makeWrapper(plane: .api, toolkit: false, recorder: recorder)
        try await mcp.recordCall(operation: {}, succeeded: { _ in true })
        try await api.recordCall(operation: {}, succeeded: { _ in true })
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .mcp, toolkit: true),
            .executionCompleted(ok: true, plane: .api, toolkit: false),
        ])
    }

    @Test func mixedSequenceCountsTerminalOutcomesOnly() async throws {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        _ = try await wrapper.recordResumable(operation: { .paused })
        _ = try await wrapper.recordResumable(operation: { nil })
        _ = try await wrapper.recordResumable(operation: { .completed(ok: true) })
        _ = try await wrapper.recordResumable(operation: { .paused })
        _ = try await wrapper.recordResumable(operation: { .completed(ok: false) })
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .mcp, toolkit: false),
            .executionCompleted(ok: false, plane: .mcp, toolkit: false),
        ])
    }

    @Test func voidCallSucceeds() async throws {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(plane: .api, toolkit: true, recorder: recorder)
        try await wrapper.recordCall(operation: {}, succeeded: { _ in true })
        #expect(await recorder.events == [
            .executionCompleted(ok: true, plane: .api, toolkit: true)
        ])
    }

    @Test func callCancellationRethrowsUnrecorded() async {
        // Mirrors Effect's `tapError`: interruption observes no outcome.
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        do {
            try await wrapper.recordCall(
                operation: { throw CancellationError() },
                succeeded: { _ in true }
            )
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected: rethrown without recording.
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(await recorder.events == [])
    }

    @Test func resumableCancellationRethrowsUnrecorded() async {
        let recorder = EventRecorder()
        let wrapper = makeWrapper(recorder: recorder)
        do {
            _ = try await wrapper.recordResumable(operation: { throw CancellationError() })
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected: rethrown without recording.
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(await recorder.events == [])
    }
}
