import Foundation
import Testing
import RVDomain

@Suite("MCPToolPolicy")
struct MCPToolPolicyTests {
    @Test func parse_canonicalLiteralYieldsFourSegments() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        #expect(address.integration == "github")
        #expect(address.owner == "acme")
        #expect(address.connection == "main")
        #expect(address.tool == "read")
        #expect(address.literal == "tools.github.acme.main.read")
    }

    @Test func parse_toolSegmentToleratesDots() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.my.tool.v2")
        #expect(address.integration == "github")
        #expect(address.owner == "acme")
        #expect(address.connection == "main")
        #expect(address.tool == "my.tool.v2")
        #expect(address.literal == "tools.github.acme.main.my.tool.v2")
    }

    @Test func parse_singleCharSegmentsAreValid() throws {
        let address = try MCPToolAddress.parse("tools.a.b.c.d")
        #expect(address.literal == "tools.a.b.c.d")
    }

    @Test func parse_segmentsMayEqualTools() throws {
        let address = try MCPToolAddress.parse("tools.tools.tools.tools.tools")
        #expect(address.integration == "tools")
        #expect(address.tool == "tools")
    }

    @Test func parse_rejectsMissingPrefix() {
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse("tool.github.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse("toolsx.github.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse("TOOLS.github.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse("tools")
        }
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse("")
        }
    }

    @Test func parse_rejectsTooFewSegments() {
        #expect(throws: MCPToolAddressError.tooFewSegments) {
            try MCPToolAddress.parse("tools.github.acme.main")
        }
        #expect(throws: MCPToolAddressError.tooFewSegments) {
            try MCPToolAddress.parse("tools.github")
        }
        #expect(throws: MCPToolAddressError.tooFewSegments) {
            try MCPToolAddress.parse("tools.")
        }
    }

    @Test func parse_rejectsEmptySegments() {
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools..acme.main.read")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github..main.read")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme..read")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme.main.")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme..")
        }
    }

    @Test func parse_rejectsEmptyPartsInsideDotTolerantTool() {
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme.main.a..b")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme.main..read")
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress.parse("tools.github.acme.main.read.")
        }
    }

    @Test func parse_enforces128CharSegmentCap() throws {
        let max = String(repeating: "a", count: 128)
        let over = String(repeating: "a", count: 129)
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try MCPToolAddress.parse("tools.\(over).acme.main.read")
        }
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try MCPToolAddress.parse("tools.github.acme.main.\(over)")
        }
        let address = try MCPToolAddress.parse("tools.\(max).acme.main.\(max)")
        #expect(address.integration.count == 128)
        #expect(address.tool.count == 128)
    }

    @Test func parse_rejectsWhitespace() {
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.git hub.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\tad")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.read\n")
        }
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try MCPToolAddress.parse(" tools.github.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.read ")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.\u{00A0}read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\u{2003}ad")
        }
    }

    @Test func parse_rejectsControlCharacters() {
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\0ad")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.gith\u{1F}ub.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\u{7F}ad")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.\u{80}main.read")
        }
    }

    @Test func parse_rejectsInvisibleFormatCharacters() {
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github\u{200B}.acme.main.read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\u{FEFF}ad")
        }
    }

    @Test func parse_rejectsC1BoundaryAndAcceptsJustAbove() throws {
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.re\u{9F}ad")
        }
        let address = try MCPToolAddress.parse("tools.github.acme.main.re\u{A1}ad")
        #expect(address.tool == "re\u{A1}ad")
    }

    @Test func parse_acceptsUnicodeSegments() throws {
        let address = try MCPToolAddress.parse("tools.héllo.世界.🔌.outil_v2")
        #expect(address.integration == "héllo")
        #expect(address.owner == "世界")
        #expect(address.connection == "🔌")
        #expect(address.tool == "outil_v2")
        #expect(address.literal == "tools.héllo.世界.🔌.outil_v2")
    }

    @Test func parse_countsCapInCharactersNotBytes() throws {
        let max = String(repeating: "é", count: 128)
        let address = try MCPToolAddress.parse("tools.\(max).acme.main.read")
        #expect(address.integration == max)
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try MCPToolAddress.parse("tools.\(max)é.acme.main.read")
        }
    }

    @Test func parse_rejectsHostileLiterals() {
        let hostile = String(repeating: "a", count: 10_000)
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try MCPToolAddress.parse("tools.\(hostile).acme.main.read")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.read\nMALICIOUS: 1")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.read\r\nBcc: x")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress.parse("tools.github.acme.main.read\u{0}tools.evil.evil.evil.evil")
        }
    }

    @Test func parse_roundTripsFixtures() throws {
        let fixtures = [
            "tools.a.b.c.d",
            "tools.github.acme.main.my.tool.v2",
            "tools.0.1.2.3",
            "tools.UPPER.lower.MiXeD.under_score-dash",
        ]
        for fixture in fixtures {
            #expect(try MCPToolAddress.parse(fixture).literal == fixture)
            #expect(try MCPToolAddress.parse(fixture) == MCPToolAddress.parse(fixture))
        }
    }

    @Test func init_validatesSegmentsDirectly() throws {
        _ = try MCPToolAddress(integration: "g", owner: "o", connection: "c", tool: "t.u")
        #expect(throws: MCPToolAddressError.emptySegment) {
            try MCPToolAddress(integration: "", owner: "o", connection: "c", tool: "t")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress(integration: "g.g", owner: "o", connection: "c", tool: "t")
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try MCPToolAddress(integration: "g", owner: "o o", connection: "c", tool: "t")
        }
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try MCPToolAddress(
                integration: "g",
                owner: "o",
                connection: String(repeating: "c", count: 129),
                tool: "t"
            )
        }
    }

    @Test func address_codableRoundTripsAsSingleString() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.my.tool")
        let data = try JSONEncoder().encode(address)
        #expect(String(data: data, encoding: .utf8) == "\"tools.github.acme.main.my.tool\"")
        #expect(try JSONDecoder().decode(MCPToolAddress.self, from: data) == address)
    }

    @Test func address_codableRejectsMalformedLiteral() {
        let data = Data("\"tools.only.two\"".utf8)
        #expect(throws: MCPToolAddressError.tooFewSegments) {
            try JSONDecoder().decode(MCPToolAddress.self, from: data)
        }
    }

    @Test func address_codableRejectsEachMalformedShape() {
        #expect(throws: MCPToolAddressError.missingToolsPrefix) {
            try JSONDecoder().decode(MCPToolAddress.self, from: Data("\"x.a.b.c.d\"".utf8))
        }
        #expect(throws: MCPToolAddressError.emptySegment) {
            try JSONDecoder().decode(MCPToolAddress.self, from: Data("\"tools..b.c.d\"".utf8))
        }
        #expect(throws: MCPToolAddressError.invalidCharacter) {
            try JSONDecoder().decode(MCPToolAddress.self, from: Data("\"tools.a.b.c.d e\"".utf8))
        }
        #expect(throws: MCPToolAddressError.segmentTooLong) {
            try JSONDecoder().decode(
                MCPToolAddress.self,
                from: Data("\"tools.\(String(repeating: "a", count: 129)).b.c.d\"".utf8)
            )
        }
    }

    @Test func address_codableRejectsNonStringJSON() {
        for literal in ["42", "null", "[]", "{}"] {
            do {
                _ = try JSONDecoder().decode(MCPToolAddress.self, from: Data(literal.utf8))
                Issue.record("expected DecodingError for \(literal)")
            } catch is DecodingError {
            } catch {
                Issue.record("wrong error type for \(literal): \(error)")
            }
        }
    }

    @Test func pattern_exactMatchesOneAddress() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let other = try MCPToolAddress.parse("tools.github.acme.main.write")
        #expect(ToolPattern.exact(address).matches(address))
        #expect(ToolPattern.exact(address).matches(other) == false)
    }

    @Test func pattern_anyMatchesEverything() throws {
        let first = try MCPToolAddress.parse("tools.a.b.c.d")
        let second = try MCPToolAddress.parse("tools.github.acme.main.my.tool.v2")
        #expect(ToolPattern.any.matches(first))
        #expect(ToolPattern.any.matches(second))
    }

    @Test func pattern_trailingPrefixMatchesByPrefix() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        #expect(ToolPattern.trailingPrefix("tools.github.").matches(address))
        #expect(ToolPattern.trailingPrefix("tools.github.acme.main.read").matches(address))
        #expect(ToolPattern.trailingPrefix("tools.gitlab.").matches(address) == false)
        #expect(ToolPattern.trailingPrefix("").matches(address))
    }

    @Test func pattern_trailingPrefixEnforcesSegmentBoundary() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.readme")
        #expect(ToolPattern.trailingPrefix("tools.github.acme.main.read").matches(address) == false)
        #expect(ToolPattern.trailingPrefix("tools.github.acme.main.read.").matches(address) == false)
        let child = try MCPToolAddress.parse("tools.github.acme.main.read.v2")
        #expect(ToolPattern.trailingPrefix("tools.github.acme.main.read").matches(child))
    }

    @Test func pattern_singleMidMatchesAroundNonEmptyMiddle() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        #expect(ToolPattern.singleMid(prefix: "tools.", suffix: ".read").matches(address))
        #expect(ToolPattern.singleMid(prefix: "tools.github.", suffix: ".main.read").matches(address))
        #expect(ToolPattern.singleMid(prefix: "tools.gitlab.", suffix: ".read").matches(address) == false)
        #expect(ToolPattern.singleMid(prefix: "tools.", suffix: ".write").matches(address) == false)
    }

    @Test func pattern_singleMidRequiresNonEmptyMiddle() throws {
        let address = try MCPToolAddress.parse("tools.a.b.c.d")
        #expect(
            ToolPattern.singleMid(prefix: "tools.a.b.c.d", suffix: "").matches(address) == false
        )
        #expect(
            ToolPattern.singleMid(prefix: "", suffix: "tools.a.b.c.d").matches(address) == false
        )
        #expect(ToolPattern.singleMid(prefix: "", suffix: "").matches(address))
    }

    @Test func pattern_singleMidRejectsOverlappingBounds() throws {
        let address = try MCPToolAddress.parse("tools.a.b.c.d")
        #expect(
            ToolPattern.singleMid(prefix: "tools.a.b.c", suffix: "b.c.d").matches(address) == false
        )
    }

    @Test func pattern_singleMidMatchesExactlyOneCharMiddle() throws {
        let address = try MCPToolAddress.parse("tools.a.b.c.d")
        #expect(ToolPattern.singleMid(prefix: "tools.a.b.c.", suffix: "").matches(address))
        #expect(
            ToolPattern.singleMid(prefix: "tools.a.b.c.d", suffix: "d").matches(address) == false
        )
    }

    @Test func pattern_singleMidAllowsDotsInMiddle() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.my.tool.v2")
        #expect(ToolPattern.singleMid(prefix: "tools.", suffix: ".v2").matches(address))
    }

    @Test func pattern_matchesUnicodeLiterals() throws {
        let address = try MCPToolAddress.parse("tools.héllo.世界.🔌.outil")
        #expect(ToolPattern.exact(address).matches(address))
        #expect(ToolPattern.trailingPrefix("tools.héllo.").matches(address))
        #expect(ToolPattern.singleMid(prefix: "tools.", suffix: ".outil").matches(address))
    }

    @Test func owner_orgOutranksUser() {
        #expect(PolicyOwner.org > PolicyOwner.user)
        #expect(PolicyOwner.user < PolicyOwner.org)
        #expect(PolicyOwner.org == PolicyOwner.org)
        #expect([PolicyOwner.org, PolicyOwner.user].sorted() == [.user, .org])
        #expect(PolicyOwner.org.rawValue == "org")
        #expect(PolicyOwner.user.rawValue == "user")
    }

    @Test func action_restrictivenessOrdersBlockAboveRequireAboveApprove() {
        #expect(PolicyAction.block > PolicyAction.requireApproval)
        #expect(PolicyAction.requireApproval > PolicyAction.approve)
        #expect(PolicyAction.approve < PolicyAction.block)
        #expect([PolicyAction.approve, PolicyAction.block, PolicyAction.requireApproval].max() == .block)
        #expect([PolicyAction.approve, PolicyAction.requireApproval].max() == .requireApproval)
        #expect(PolicyAction.requireApproval.rawValue == "require_approval")
    }

    @Test func policy_holdsItsParts() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let policy = ToolPolicy(
            id: "p1",
            owner: .org,
            pattern: .exact(address),
            action: .block,
            position: FractionalIndex(value: 1.5)
        )
        #expect(policy.id == "p1")
        #expect(policy.owner == .org)
        #expect(policy.pattern == .exact(address))
        #expect(policy.action == .block)
        #expect(policy.position == FractionalIndex(value: 1.5))
        #expect(policy.pattern.matches(address))
    }

    @Test func policy_codableRoundTrips() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let policy = ToolPolicy(
            id: "p1",
            owner: .user,
            pattern: .singleMid(prefix: "tools.", suffix: ".read"),
            action: .requireApproval,
            position: FractionalIndex(value: 2)
        )
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(ToolPolicy.self, from: data) == policy)
        #expect(policy.pattern.matches(address))
    }

    @Test func pattern_codableRoundTripsEveryVariant() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let patterns: [ToolPattern] = [
            .exact(address),
            .any,
            .trailingPrefix("tools.github."),
            .singleMid(prefix: "tools.", suffix: ".read"),
            try .segments(SegmentPattern.parse("tools.github.*.main.read")),
        ]
        for pattern in patterns {
            let data = try JSONEncoder().encode(pattern)
            #expect(try JSONDecoder().decode(ToolPattern.self, from: data) == pattern)
        }
    }

    @Test func policy_codableRoundTripsExactPattern() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let policy = ToolPolicy(
            id: "p1",
            owner: .org,
            pattern: .exact(address),
            action: .block,
            position: FractionalIndex(value: 1)
        )
        let data = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(ToolPolicy.self, from: data) == policy)
    }

    @Test func action_rawValuesAreStable() {
        #expect(PolicyAction.approve.rawValue == "approve")
        #expect(PolicyAction.block.rawValue == "block")
    }

    @Test func fractionalIndex_comparableOrdersByValue() {
        #expect(FractionalIndex(value: 1) < FractionalIndex(value: 2))
        #expect(FractionalIndex(value: -1) < FractionalIndex(value: 0))
        #expect(FractionalIndex(value: 2) > FractionalIndex(value: 1.5))
        #expect(FractionalIndex(value: 1) == FractionalIndex(value: 1))
        #expect([FractionalIndex(value: 3), FractionalIndex(value: 1)].sorted().first?.value == 1)
    }

    @Test func fractionalIndex_betweenReturnsMidpoint() {
        #expect(FractionalIndex.between(.init(value: 1), .init(value: 3)) == .init(value: 2))
        #expect(FractionalIndex.between(.init(value: -4), .init(value: 4)) == .init(value: 0))
        #expect(FractionalIndex.between(.init(value: 0), .init(value: 1)) == .init(value: 0.5))
    }

    @Test func fractionalIndex_betweenIsOrderAgnostic() {
        let forward = FractionalIndex.between(.init(value: 1), .init(value: 3))
        let backward = FractionalIndex.between(.init(value: 3), .init(value: 1))
        #expect(forward == backward)
        #expect(forward.value > 1 && forward.value < 3)
    }

    @Test func fractionalIndex_betweenEqualValuesReturnsSame() {
        #expect(FractionalIndex.between(.init(value: 2), .init(value: 2)) == .init(value: 2))
    }

    @Test func fractionalIndex_betweenExtremeFiniteValuesStaysBetween() {
        let low = FractionalIndex(value: 1e15)
        let high = FractionalIndex(value: 1e15 + 2)
        let mid = FractionalIndex.between(low, high)
        #expect(mid.value > low.value && mid.value < high.value)
    }

    @Test func fractionalIndex_betweenOppositeInfinitiesFallsBackToFirst() {
        let first = FractionalIndex(value: .infinity)
        #expect(FractionalIndex.between(first, FractionalIndex(value: -.infinity)) == first)
    }

    @Test func fractionalIndex_decodeRejectsNaN() throws {
        // PropertyList can express NaN where JSON cannot.
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>value</key><real>nan</real></dict></plist>
            """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try PropertyListDecoder().decode(FractionalIndex.self, from: plist)
        }
    }
}

@Suite("SegmentPatternGrammar")
struct SegmentPatternGrammarTests {
    // Parse accept matrix. Valid fixtures mirror Executor isValidPattern (policies.test.ts:83-98).

    @Test func parse_universalWildcard() throws {
        let pattern = try SegmentPattern.parse("*")
        #expect(pattern == .any)
        #expect(pattern.rawValue == "*")
        #expect(pattern.specificity == 0)
    }

    @Test func parse_exactShapes() throws {
        #expect(try SegmentPattern.parse("a") == .exact(segments: ["a"]))
        #expect(try SegmentPattern.parse("a.b") == .exact(segments: ["a", "b"]))
        #expect(try SegmentPattern.parse("a.b.c") == .exact(segments: ["a", "b", "c"]))
        #expect(
            try SegmentPattern.parse("tools.a.b.c.d")
                == .exact(segments: ["tools", "a", "b", "c", "d"])
        )
    }

    @Test func parse_trailingWildcardIsSubtree() throws {
        #expect(
            try SegmentPattern.parse("a.*")
                == .wildcard(segments: [.literal("a")], subtree: true)
        )
        #expect(
            try SegmentPattern.parse("a.b.*")
                == .wildcard(segments: [.literal("a"), .literal("b")], subtree: true)
        )
    }

    @Test func parse_singleMidWildcard() throws {
        #expect(
            try SegmentPattern.parse("a.*.b")
                == .wildcard(
                    segments: [.literal("a"), .wildcard, .literal("b")],
                    subtree: false
                )
        )
    }

    @Test func parse_repeatedMidWildcards() throws {
        let pattern = try SegmentPattern.parse("github.*.*.repos.list")
        #expect(
            pattern
                == .wildcard(
                    segments: [
                        .literal("github"), .wildcard, .wildcard,
                        .literal("repos"), .literal("list"),
                    ],
                    subtree: false
                )
        )
        #expect(pattern.specificity == 11)
    }

    @Test func parse_midPlusTrailingWildcards() throws {
        #expect(
            try SegmentPattern.parse("github.*.*.repos.*")
                == .wildcard(
                    segments: [
                        .literal("github"), .wildcard, .wildcard, .literal("repos"),
                    ],
                    subtree: true
                )
        )
    }

    @Test func parse_toolsAnchoredPatterns() throws {
        #expect(
            try SegmentPattern.parse("tools.github.*.main.read")
                == .wildcard(
                    segments: [
                        .literal("tools"), .literal("github"), .wildcard,
                        .literal("main"), .literal("read"),
                    ],
                    subtree: false
                )
        )
        #expect(
            try SegmentPattern.parse("tools.*")
                == .wildcard(segments: [.literal("tools")], subtree: true)
        )
    }

    @Test func parse_acceptsAnyLiteralText() throws {
        // Executor performs no character or length checks; a literal no valid
        // address can contain simply never matches.
        #expect(try SegmentPattern.parse("a.b c") == .exact(segments: ["a", "b c"]))
        #expect(try SegmentPattern.parse("TOOLS.a") == .exact(segments: ["TOOLS", "a"]))
        #expect(try SegmentPattern.parse("a.é.🔌") == .exact(segments: ["a", "é", "🔌"]))
        let long = String(repeating: "z", count: 500)
        #expect(try SegmentPattern.parse("a.\(long)") == .exact(segments: ["a", long]))
    }

    @Test func parse_allExecutorValidFixtures() throws {
        let valid = [
            "a", "a.b", "a.b.c", "a.*", "a.b.*",
            "a.*.b", "github.*.*.repos.list", "github.*.*.repos.*",
            "github.user.alice.repos.*", "*",
        ]
        for fixture in valid {
            #expect(SegmentPattern.isValid(fixture), "expected valid: \(fixture)")
            _ = try SegmentPattern.parse(fixture)
        }
    }

    // Parse rejection shapes. Invalid fixtures mirror Executor isValidPattern (policies.test.ts:102-108).

    @Test func parse_rejectsEmpty() {
        #expect(throws: ToolPatternError.emptyPattern) {
            try SegmentPattern.parse("")
        }
    }

    @Test func parse_rejectsLeadingDot() {
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse(".a")
        }
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse(".")
        }
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse("..a")
        }
    }

    @Test func parse_rejectsTrailingDot() {
        #expect(throws: ToolPatternError.trailingDot) {
            try SegmentPattern.parse("a.")
        }
        #expect(throws: ToolPatternError.trailingDot) {
            try SegmentPattern.parse("a..")
        }
    }

    @Test func parse_rejectsEmptySegment() {
        #expect(throws: ToolPatternError.emptySegment) {
            try SegmentPattern.parse("a..b")
        }
        #expect(throws: ToolPatternError.emptySegment) {
            try SegmentPattern.parse("a...b")
        }
    }

    @Test func parse_rejectsLeadingWildcard() {
        #expect(throws: ToolPatternError.leadingWildcard) {
            try SegmentPattern.parse("*.a")
        }
        #expect(throws: ToolPatternError.leadingWildcard) {
            try SegmentPattern.parse("*.*")
        }
        #expect(throws: ToolPatternError.leadingWildcard) {
            try SegmentPattern.parse("**")
        }
        #expect(throws: ToolPatternError.leadingWildcard) {
            try SegmentPattern.parse("**.a")
        }
    }

    @Test func parse_rejectsPartialWildcard() {
        #expect(throws: ToolPatternError.partialWildcard) {
            try SegmentPattern.parse("a*")
        }
        #expect(throws: ToolPatternError.partialWildcard) {
            try SegmentPattern.parse("a.b*")
        }
        #expect(throws: ToolPatternError.partialWildcard) {
            try SegmentPattern.parse("a*b.c")
        }
        #expect(throws: ToolPatternError.partialWildcard) {
            try SegmentPattern.parse("a.*b")
        }
        #expect(throws: ToolPatternError.partialWildcard) {
            try SegmentPattern.parse("a.**.b")
        }
    }

    @Test func parse_firstFailureWinsInExecutorOrder() {
        // ".*": the leading-dot check precedes the trailing-dot check.
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse(".*")
        }
        // "*.": the trailing-dot check precedes the leading-wildcard check.
        #expect(throws: ToolPatternError.trailingDot) {
            try SegmentPattern.parse("*.")
        }
        // "*..a": the empty-segment check precedes the leading-wildcard check.
        #expect(throws: ToolPatternError.emptySegment) {
            try SegmentPattern.parse("*..a")
        }
        // "*.a*": the leading-wildcard check precedes the partial-wildcard scan.
        #expect(throws: ToolPatternError.leadingWildcard) {
            try SegmentPattern.parse("*.a*")
        }
    }

    @Test func parse_errorsNeverEchoInput() {
        let hostile = "sk-live-\(String(repeating: "x", count: 64))*ADMIN"
        let cases: [(String, ToolPatternError)] = [
            ("", .emptyPattern),
            (".\(hostile)", .leadingDot),
            ("\(hostile).", .trailingDot),
            ("a..\(hostile)", .emptySegment),
            ("*.\(hostile)", .leadingWildcard),
            (hostile, .partialWildcard),
        ]
        for (input, expected) in cases {
            do {
                _ = try SegmentPattern.parse(input)
                Issue.record("expected \(expected) for rejected input")
            } catch let error as ToolPatternError {
                #expect(error == expected)
                #expect(String(describing: error).contains(hostile) == false)
            } catch {
                Issue.record("wrong error type: \(error)")
            }
        }
    }

    // isValid mirrors Executor isValidPattern accept/reject on every input.

    @Test func isValid_mirrorsExecutorFixtures() {
        let valid = [
            "a", "a.b", "a.b.c", "a.*", "a.b.*",
            "a.*.b", "github.*.*.repos.list", "github.*.*.repos.*",
            "github.user.alice.repos.*", "*",
        ]
        let invalid = ["", ".a", "a.", "a..b", "*.a", "a*", "a.b*"]
        for fixture in valid {
            #expect(SegmentPattern.isValid(fixture), "expected valid: \(fixture)")
        }
        for fixture in invalid {
            #expect(SegmentPattern.isValid(fixture) == false, "expected invalid: \(fixture)")
        }
    }

    @Test func isValid_agreesWithParse() throws {
        let raws = [
            "*", "a", "tools.*", "tools.*.*", "a.*.*.*.b", "a b.c", "a b",
            "x.y.z.*", ".", "..", "*.", ".*", "**", "a.**.b", "*.a*",
            "", "a.", ".a", "a..b", "*.a", "a*",
        ]
        for raw in raws {
            let parsed: SegmentPattern?
            do {
                parsed = try SegmentPattern.parse(raw)
            } catch {
                parsed = nil
            }
            #expect(SegmentPattern.isValid(raw) == (parsed != nil), "agreement for: \(raw)")
        }
    }

    // rawValue roundtrips and Codable.

    @Test func rawValue_roundTrips() throws {
        let fixtures = [
            "*", "a", "a.b.c", "a.*", "a.b.*", "a.*.b",
            "github.*.*.repos.list", "github.*.*.repos.*",
            "github.user.alice.repos.*", "tools.github.*.main.read", "tools.*",
        ]
        for fixture in fixtures {
            let pattern = try SegmentPattern.parse(fixture)
            #expect(pattern.rawValue == fixture, "canonical form of \(fixture)")
            #expect(try SegmentPattern.parse(pattern.rawValue) == pattern)
        }
    }

    @Test func codable_roundTripsEveryShape() throws {
        let patterns: [SegmentPattern] = [
            .any,
            .exact(segments: ["a", "b"]),
            .wildcard(segments: [.literal("a"), .wildcard], subtree: false),
            .wildcard(segments: [.literal("a")], subtree: true),
        ]
        for pattern in patterns {
            let data = try JSONEncoder().encode(pattern)
            #expect(try JSONDecoder().decode(SegmentPattern.self, from: data) == pattern)
        }
        let segments: [PatternSegment] = [.literal("a"), .wildcard]
        for segment in segments {
            let data = try JSONEncoder().encode(segment)
            #expect(try JSONDecoder().decode(PatternSegment.self, from: data) == segment)
        }
    }

    // matches. Fixtures mirror Executor matchPattern (policies.test.ts:33-77).

    @Test func matches_exactRequiresFullEquality() throws {
        let pattern = try SegmentPattern.parse("vercel.dns.create")
        #expect(pattern.matches(literal: "vercel.dns.create"))
        #expect(pattern.matches(literal: "vercel.dns.delete") == false)
    }

    @Test func matches_trailingWildcardIsSubtree() throws {
        let pattern = try SegmentPattern.parse("vercel.dns.*")
        #expect(pattern.matches(literal: "vercel.dns.create"))
        #expect(pattern.matches(literal: "vercel.dns.delete"))
        #expect(pattern.matches(literal: "vercel.dns.zones.list"))
        #expect(pattern.matches(literal: "vercel.dnstool") == false)
        #expect(pattern.matches(literal: "vercel.deploy") == false)
    }

    @Test func matches_pluginWide() throws {
        let pattern = try SegmentPattern.parse("vercel.*")
        #expect(pattern.matches(literal: "vercel.dns.create"))
        #expect(pattern.matches(literal: "vercel.deploy"))
        #expect(pattern.matches(literal: "vercelapp.deploy") == false)
    }

    @Test func matches_universal() throws {
        let pattern = try SegmentPattern.parse("*")
        #expect(pattern.matches(literal: "vercel.dns.create"))
        #expect(pattern.matches(literal: "github.repos.list"))
        #expect(pattern.matches(literal: "x"))
        #expect(pattern.matches(literal: ""))
    }

    @Test func matches_repeatedMidWildcard() throws {
        let pattern = try SegmentPattern.parse("github.*.*.repos.list")
        #expect(pattern.matches(literal: "github.org.acme.repos.list"))
        #expect(pattern.matches(literal: "github.user.alice.repos.list"))
        #expect(pattern.matches(literal: "github.org.acme.repos.delete") == false)
        #expect(pattern.matches(literal: "github.acme.repos.list") == false)
    }

    @Test func matches_midPlusTrailing() throws {
        let pattern = try SegmentPattern.parse("github.*.*.repos.*")
        #expect(pattern.matches(literal: "github.org.acme.repos.list"))
        #expect(pattern.matches(literal: "github.org.acme.repos"))
        #expect(pattern.matches(literal: "github.org.acme.deploy") == false)
        let scoped = try SegmentPattern.parse("github.user.alice.repos.*")
        #expect(scoped.matches(literal: "github.user.alice.repos.list"))
        #expect(scoped.matches(literal: "github.user.bob.repos.list") == false)
    }

    @Test func matches_midWildcardConsumesExactlyOneSegment() throws {
        let pattern = try SegmentPattern.parse("a.*.c")
        #expect(pattern.matches(literal: "a.b.c"))
        #expect(pattern.matches(literal: "a.b.b.c") == false)
        #expect(pattern.matches(literal: "a.c") == false)
        #expect(pattern.matches(literal: "a.b.c.d") == false)
    }

    @Test func matches_shortAddressFailsMidWildcard() throws {
        // A mid-`*` needs a segment to consume: the address ends first.
        let pattern = try SegmentPattern.parse("a.b.*.d")
        #expect(pattern.matches(literal: "a.b.c.d"))
        #expect(pattern.matches(literal: "a.b") == false)
        #expect(pattern.matches(literal: "a") == false)
    }

    @Test func matches_trailingWildcardMatchesPrefixItself() throws {
        // Executor trailing `*` matches "at this position and anything deeper (or nothing)".
        #expect(try SegmentPattern.parse("a.*").matches(literal: "a"))
        #expect(try SegmentPattern.parse("a.b.*").matches(literal: "a.b"))
    }

    @Test func matches_addressOverload() throws {
        let read = try MCPToolAddress.parse("tools.github.acme.main.read")
        let write = try MCPToolAddress.parse("tools.github.acme.main.write")
        let dotted = try MCPToolAddress.parse("tools.github.acme.main.my.tool.v2")
        let mid = try SegmentPattern.parse("tools.github.*.main.read")
        #expect(mid.matches(read))
        #expect(mid.matches(write) == false)
        #expect(mid.matches(dotted) == false)
        #expect(try SegmentPattern.parse("tools.github.acme.main.*").matches(dotted))
        #expect(try SegmentPattern.parse("tools.github.acme.main.read").matches(read))
        #expect(try SegmentPattern.parse("tools.github.acme.main.read").matches(write) == false)
        #expect(SegmentPattern.any.matches(read))
    }

    @Test func matches_isCaseSensitive() throws {
        #expect(try SegmentPattern.parse("A.*").matches(literal: "a.b") == false)
        #expect(try SegmentPattern.parse("a.B").matches(literal: "a.b") == false)
    }

    @Test func matches_emptyLiteral() throws {
        #expect(try SegmentPattern.parse("*").matches(literal: ""))
        #expect(try SegmentPattern.parse("a.*").matches(literal: "") == false)
        #expect(try SegmentPattern.parse("a").matches(literal: "") == false)
    }

    // specificity. Formula and table mirror Executor patternSpecificity (policies.ts:195).

    @Test func specificity_matchesExecutorTable() throws {
        #expect(try SegmentPattern.parse("*").specificity == 0)
        #expect(try SegmentPattern.parse("vercel.*").specificity == 2)
        #expect(try SegmentPattern.parse("vercel.dns.*").specificity == 4)
        #expect(try SegmentPattern.parse("vercel.dns").specificity == 5)
        #expect(try SegmentPattern.parse("vercel.dns.create").specificity == 7)
    }

    @Test func specificity_exactBeatsSamePrefixWildcard() throws {
        let pairs = [("a.b", "a.b.*"), ("a.b.c", "a.b.c.*"), ("tools.a", "tools.a.*")]
        for (exact, wildcard) in pairs {
            let exactScore = try SegmentPattern.parse(exact).specificity
            let wildcardScore = try SegmentPattern.parse(wildcard).specificity
            #expect(exactScore == wildcardScore + 1, "\(exact) beats \(wildcard)")
        }
        let chain = ["*", "a.*", "a.b.*", "a.b", "a.b.c.*", "a.b.c"]
        var previous = -1
        for raw in chain {
            let score = try SegmentPattern.parse(raw).specificity
            #expect(score > previous, "\(raw) orders above previous")
            previous = score
        }
    }

    @Test func specificity_countsMidWildcardsAsSegments() throws {
        // Executor counts every non-trailing segment, mid-`*` included.
        #expect(try SegmentPattern.parse("github.*.*.repos.list").specificity == 11)
        #expect(try SegmentPattern.parse("github.*.*.repos.*").specificity == 8)
        #expect(try SegmentPattern.parse("a.*.b").specificity == 7)
    }
}

@Suite("SegmentPatternPlacement")
struct SegmentPatternPlacementTests {
    // Default placement mirrors Executor positionForNewPattern (policies.ts:213).

    private typealias Row = (id: String, pattern: SegmentPattern, position: FractionalIndex)

    private func row(_ id: String, _ raw: String, _ value: Double) throws -> Row {
        (id: id, pattern: try SegmentPattern.parse(raw), position: FractionalIndex(value: value))
    }

    @Test func position_emptyRowsReturnsZero() throws {
        let pattern = try SegmentPattern.parse("a.*")
        let noRows: [Row] = []
        #expect(SegmentPattern.positionForNewPattern(pattern, rows: noRows) == FractionalIndex(value: 0))
    }

    @Test func position_singleRow() throws {
        let leaf = try row("leaf", "a.b.c", 4)
        let group = try SegmentPattern.parse("a.*")
        #expect(
            SegmentPattern.positionForNewPattern(group, rows: [leaf]) == FractionalIndex(value: 5)
        )
        let leafier = try SegmentPattern.parse("a.b.c.d")
        #expect(
            SegmentPattern.positionForNewPattern(leafier, rows: [leaf]) == FractionalIndex(value: 3)
        )
    }

    @Test func position_newMostSpecificGoesAboveAll() throws {
        let rows = try [row("a", "a.*", 2), row("b", "a.b.*", 4)]
        let leaf = try SegmentPattern.parse("a.b.c")
        let position = SegmentPattern.positionForNewPattern(leaf, rows: rows)
        #expect(position == FractionalIndex(value: 1))
    }

    @Test func position_newLeastSpecificGoesBelowAll() throws {
        let rows = try [row("a", "a.b.c", 2), row("b", "a.b.c.d", 4)]
        let group = try SegmentPattern.parse("a.*")
        let position = SegmentPattern.positionForNewPattern(group, rows: rows)
        #expect(position == FractionalIndex(value: 5))
    }

    @Test func position_newMiddleUsesBetween() throws {
        let rows = try [row("leaf", "a.b.c", 0), row("group", "a.*", 10)]
        let middle = try SegmentPattern.parse("a.b.*")
        let position = SegmentPattern.positionForNewPattern(middle, rows: rows)
        #expect(
            position
                == FractionalIndex.between(FractionalIndex(value: 0), FractionalIndex(value: 10))
        )
        #expect(position == FractionalIndex(value: 5))
    }

    @Test func position_newGoesAboveEquallySpecificRows() throws {
        // Executor `<=`: equally specific rows sort at or after the newcomer.
        let rows = try [row("a", "x.y", 2), row("b", "m.n", 4)]
        let peer = try SegmentPattern.parse("a.b")
        let position = SegmentPattern.positionForNewPattern(peer, rows: rows)
        #expect(position == FractionalIndex(value: 1))
    }

    @Test func position_sortsUnsortedInput() throws {
        let rows = try [
            row("group", "a.*", 10),
            row("leaf", "a.b.c", 0),
        ]
        let middle = try SegmentPattern.parse("a.b.*")
        #expect(
            SegmentPattern.positionForNewPattern(middle, rows: rows) == FractionalIndex(value: 5)
        )
    }

    @Test func position_tieBreaksEqualPositionsById() throws {
        // Equal positions sort by id before placement: input order runs against
        // id order, so a position-only sort would land between 0 and 1.
        let rows = try [
            row("b", "q.*", 1),
            row("lo", "a.b.c", 0),
            row("a", "x.y.z", 1),
        ]
        let middle = try SegmentPattern.parse("m.n")
        let position = SegmentPattern.positionForNewPattern(middle, rows: rows)
        // Sorted: (0,lo,7),(1,a,7),(1,b,2); first specificity <= 5 is b at index 2.
        #expect(position == FractionalIndex(value: 1))
    }

    @Test func position_neverShadowsLeafProperty() throws {
        // Fresh group rules never shadow leaf rules: over random rule sets
        // whose positions already run most-specific-first (the invariant every
        // placed rule maintains), the newcomer lands strictly below every
        // more-specific row and strictly above every equally or less specific
        // row. A second loop asserts the unconditional edges on fully random
        // sets: a strictly least-specific newcomer lands below the maximum, a
        // strictly most-specific (or peer-or-better) newcomer above the minimum.
        let pool = [
            "*", "a.*", "a.b.*", "a.b", "m.n", "a.b.c",
            "x.y.z.*", "a.b.c.d", "q.*.z", "k.l.m.n.*",
        ]
        var rng: UInt64 = 0x1234_5678_9ABC_DEF1
        func next(_ upper: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(upper))
        }
        for iteration in 0..<300 {
            let count = next(9)
            var patterns: [SegmentPattern] = []
            for _ in 0..<count {
                patterns.append(try SegmentPattern.parse(pool[next(pool.count)]))
            }
            // Most-specific-first positions, then shuffled input order.
            patterns.sort { $0.specificity > $1.specificity }
            var rows: [Row] = []
            for (i, pattern) in patterns.enumerated() {
                rows.append((
                    id: "r\(iteration)-\(i)",
                    pattern: pattern,
                    position: FractionalIndex(value: Double(i))
                ))
            }
            for i in stride(from: rows.count - 1, through: 1, by: -1) {
                rows.swapAt(i, next(i + 1))
            }
            let newcomer = try SegmentPattern.parse(pool[next(pool.count)])
            let placed = SegmentPattern.positionForNewPattern(newcomer, rows: rows)
            for rule in rows {
                if rule.pattern.specificity > newcomer.specificity {
                    #expect(
                        rule.position < placed,
                        "iter \(iteration): more-specific \(rule.pattern.rawValue) stays above"
                    )
                } else {
                    #expect(
                        placed < rule.position,
                        "iter \(iteration): newcomer stays above \(rule.pattern.rawValue)"
                    )
                }
            }
        }
        // No universal pattern here: the floor newcomer must be strictly least specific.
        let raised = pool.filter { $0 != "*" }
        for iteration in 0..<300 {
            let count = next(9)
            var rows: [Row] = []
            for i in 0..<count {
                let pattern = try SegmentPattern.parse(raised[next(raised.count)])
                let value = Double(next(33)) / 2 - 4
                rows.append((
                    id: "s\(iteration)-\(i)",
                    pattern: pattern,
                    position: FractionalIndex(value: value)
                ))
            }
            guard let minimum = rows.map(\.position).min(),
                let maximum = rows.map(\.position).max()
            else {
                continue
            }
            let floor = try SegmentPattern.parse("*")
            let ceiling = try SegmentPattern.parse("w.x.y.z.*.v")
            let below = SegmentPattern.positionForNewPattern(floor, rows: rows)
            let above = SegmentPattern.positionForNewPattern(ceiling, rows: rows)
            #expect(below > maximum, "iter \(iteration): universal lands below the maximum")
            #expect(above < minimum, "iter \(iteration): sharpest pattern lands above the minimum")
        }
    }

    @Test func specificity_toolPatternLegacyMapping() throws {
        let address = try MCPToolAddress.parse("tools.github.user.main.repos.list")
        // Six literal segments: 6 * 2 + 1 exact bonus.
        #expect(ToolPattern.exact(address).specificity == 13)
        #expect(ToolPattern.any.specificity == 0)
        // Trailing-dot or not, the prefix scores its real segments, no bonus.
        #expect(ToolPattern.trailingPrefix("tools.github.").specificity == 4)
        #expect(ToolPattern.trailingPrefix("tools.github").specificity == 4)
        #expect(ToolPattern.trailingPrefix("").specificity == 0)
        // Prefix-plus-suffix segments, doubled.
        #expect(ToolPattern.singleMid(prefix: "tools.a.", suffix: ".list").specificity == 6)
        #expect(ToolPattern.singleMid(prefix: "", suffix: "").specificity == 0)
        // Segment patterns delegate untouched.
        #expect(ToolPattern.segments(try SegmentPattern.parse("a.b.*")).specificity == 4)
        #expect(ToolPattern.segments(try SegmentPattern.parse("a.b.c")).specificity == 7)
        #expect(ToolPattern.segments(try SegmentPattern.parse("*")).specificity == 0)
    }

    @Test func position_toolPatternRowsPlaceAmongLegacy() throws {
        typealias LegacyRow = (id: String, pattern: ToolPattern, position: FractionalIndex)
        let leaf = try MCPToolAddress.parse("tools.github.user.main.repos.list")
        let rows: [LegacyRow] = [
            (id: "exact", pattern: .exact(leaf), position: FractionalIndex(value: 0)),
            (id: "any", pattern: .any, position: FractionalIndex(value: 10)),
        ]
        // Newcomer (score 4) lands between the exact leaf (13) and `any` (0).
        let middle = SegmentPattern.positionForNewPattern(
            try SegmentPattern.parse("a.b.*"), rows: rows
        )
        #expect(middle == FractionalIndex(value: 5))
        // Sharper than every row lands above; with only the leaf committed,
        // the universal newcomer lands below it.
        let above = SegmentPattern.positionForNewPattern(
            try SegmentPattern.parse("a.b.c.d.e.f.g"), rows: rows
        )
        #expect(above == FractionalIndex(value: -1))
        let below = SegmentPattern.positionForNewPattern(
            try SegmentPattern.parse("*"), rows: [(id: "exact", pattern: ToolPattern.exact(leaf), position: FractionalIndex(value: 0))]
        )
        #expect(below == FractionalIndex(value: 1))
        // The exact bonus is load-bearing: a score-12 newcomer lands below
        // the exact leaf (13) — without the bonus it would land above.
        let bonusProof = SegmentPattern.positionForNewPattern(
            try SegmentPattern.parse("a.b.c.d.e.f.*"), rows: rows
        )
        #expect(bonusProof == FractionalIndex(value: 5))
        // A legacy prefix row holds its mapped place (score 4): the equally
        // specific newcomer lands above it.
        let prefixed: [LegacyRow] = [
            (id: "prefix", pattern: .trailingPrefix("tools.github."), position: FractionalIndex(value: 7)),
        ]
        let peer = SegmentPattern.positionForNewPattern(
            try SegmentPattern.parse("a.b.*"), rows: prefixed
        )
        #expect(peer == FractionalIndex(value: 6))
    }

    @Test func position_toolPatternRowsNeverShadowLeaf() throws {
        // Mixed legacy + segment rows: the newcomer still lands strictly
        // below every more-specific row and strictly above every equally or
        // less specific one, so fresh group rules never shadow leaf rules.
        let addresses = try [
            "tools.github.user.main.repos.list",
            "tools.github.org.ops.deploy",
            "tools.i.o.c.t",
        ].map(MCPToolAddress.parse)
        let pool: [ToolPattern] = [
            .any,
            .exact(addresses[0]),
            .exact(addresses[2]),
            .trailingPrefix("tools.github."),
            .trailingPrefix("tools.i.o"),
            .singleMid(prefix: "tools.", suffix: ".list"),
            .singleMid(prefix: "x", suffix: "y"),
            .segments(try SegmentPattern.parse("*")),
            .segments(try SegmentPattern.parse("a.*")),
            .segments(try SegmentPattern.parse("a.b.c")),
            .segments(try SegmentPattern.parse("q.*.z")),
        ]
        let newcomers = try [
            SegmentPattern.parse("*"),
            SegmentPattern.parse("a.*"),
            SegmentPattern.parse("a.b.c"),
            SegmentPattern.parse("m.n"),
        ]
        var rng: UInt64 = 0x5EED_1234_ABCD_0042
        func next(_ upper: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(upper))
        }
        for iteration in 0..<300 {
            let count = next(9)
            var patterns: [ToolPattern] = []
            for _ in 0..<count {
                patterns.append(pool[next(pool.count)])
            }
            patterns.sort { $0.specificity > $1.specificity }
            var rows: [(id: String, pattern: ToolPattern, position: FractionalIndex)] = []
            for (i, pattern) in patterns.enumerated() {
                rows.append((
                    id: "m\(iteration)-\(i)",
                    pattern: pattern,
                    position: FractionalIndex(value: Double(i))
                ))
            }
            for i in stride(from: rows.count - 1, through: 1, by: -1) {
                rows.swapAt(i, next(i + 1))
            }
            let newcomer = newcomers[next(newcomers.count)]
            let placed = SegmentPattern.positionForNewPattern(newcomer, rows: rows)
            for rule in rows {
                if rule.pattern.specificity > newcomer.specificity {
                    #expect(
                        rule.position < placed,
                        "iter \(iteration): more-specific row stays above"
                    )
                } else {
                    #expect(
                        placed < rule.position,
                        "iter \(iteration): newcomer stays above equally-or-less row"
                    )
                }
            }
        }
    }
}

@Suite("ToolPatternSegments")
struct ToolPatternSegmentsTests {
    // Wiring: the Executor grammar is reachable through the policy path.
    // `ToolPattern.parse` always yields `.segments`; `matches` delegates.

    @Test func segments_matchesRepeatedMidWildcard() throws {
        let pattern = try ToolPattern.parse("tools.*.*.main.read")
        let hit = try MCPToolAddress.parse("tools.github.acme.main.read")
        #expect(pattern.matches(hit))
        #expect(pattern.matches(try MCPToolAddress.parse("tools.github.acme.main.write")) == false)
        #expect(pattern.matches(try MCPToolAddress.parse("tools.github.acme.main.my.read")) == false)
        #expect(pattern.matches(try MCPToolAddress.parse("tools.github.acme.other.read")) == false)
    }

    @Test func segments_matchesSingleMidWildcard() throws {
        let pattern = try ToolPattern.parse("tools.github.*.main.read")
        #expect(pattern.matches(try MCPToolAddress.parse("tools.github.acme.main.read")))
        #expect(pattern.matches(try MCPToolAddress.parse("tools.github.acme.main.write")) == false)
        #expect(pattern.matches(try MCPToolAddress.parse("tools.gitlab.acme.main.read")) == false)
    }

    @Test func segments_matchesSubtreeExactAndUniversal() throws {
        let subtree = try ToolPattern.parse("tools.github.acme.main.*")
        #expect(subtree.matches(try MCPToolAddress.parse("tools.github.acme.main.my.tool.v2")))
        #expect(subtree.matches(try MCPToolAddress.parse("tools.github.acme.main.read")))
        #expect(subtree.matches(try MCPToolAddress.parse("tools.github.acme.other.read")) == false)
        let exact = try ToolPattern.parse("tools.github.acme.main.read")
        #expect(exact.matches(try MCPToolAddress.parse("tools.github.acme.main.read")))
        #expect(exact.matches(try MCPToolAddress.parse("tools.github.acme.main.write")) == false)
        // Uniform wrap: even the universal pattern parses to `.segments`, never `.any`.
        #expect(try ToolPattern.parse("*") == .segments(.any))
        #expect(try ToolPattern.parse("*").matches(try MCPToolAddress.parse("tools.a.b.c.d")))
    }

    @Test func parse_alwaysYieldsSegments() throws {
        let fixtures = [
            "*", "a", "a.b.c", "a.*", "a.b.*", "a.*.b",
            "github.*.*.repos.list", "github.*.*.repos.*",
            "github.user.alice.repos.*", "tools.github.*.main.read", "tools.*",
        ]
        for fixture in fixtures {
            #expect(
                try ToolPattern.parse(fixture) == .segments(try SegmentPattern.parse(fixture)),
                "parse wraps \(fixture)"
            )
        }
    }

    @Test func parse_rejectsWithSegmentErrors() {
        let cases: [(String, ToolPatternError)] = [
            ("", .emptyPattern),
            (".a", .leadingDot),
            ("a.", .trailingDot),
            ("a..b", .emptySegment),
            ("*.a", .leadingWildcard),
            ("**", .leadingWildcard),
            ("a*", .partialWildcard),
            ("a.**.b", .partialWildcard),
        ]
        for (input, expected) in cases {
            do {
                _ = try ToolPattern.parse(input)
                Issue.record("expected \(expected) for rejected input")
            } catch let error as ToolPatternError {
                #expect(error == expected)
            } catch {
                Issue.record("wrong error type: \(error)")
            }
        }
    }

    @Test func isValid_parityWithSegmentPattern() {
        let valid = [
            "a", "a.b", "a.b.c", "a.*", "a.b.*",
            "a.*.b", "github.*.*.repos.list", "github.*.*.repos.*",
            "github.user.alice.repos.*", "*",
        ]
        let invalid = ["", ".a", "a.", "a..b", "*.a", "a*", "a.b*"]
        for fixture in valid {
            #expect(ToolPattern.isValid(fixture), "expected valid: \(fixture)")
        }
        for fixture in invalid {
            #expect(ToolPattern.isValid(fixture) == false, "expected invalid: \(fixture)")
        }
    }

    @Test func codable_roundTripsSegmentsCase() throws {
        let pattern = try ToolPattern.parse("tools.github.*.main.read")
        let data = try JSONEncoder().encode(pattern)
        #expect(try JSONDecoder().decode(ToolPattern.self, from: data) == pattern)
        let policy = ToolPolicy(
            id: "p1",
            owner: .org,
            pattern: pattern,
            action: .block,
            position: FractionalIndex(value: 1)
        )
        let policyData = try JSONEncoder().encode(policy)
        #expect(try JSONDecoder().decode(ToolPolicy.self, from: policyData) == policy)
    }

    @Test func policy_carriesSegmentsPattern() throws {
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let policy = ToolPolicy(
            id: "p1",
            owner: .user,
            pattern: try ToolPattern.parse("tools.*.*.main.read"),
            action: .approve,
            position: FractionalIndex(value: 1)
        )
        #expect(policy.pattern.matches(address))
        #expect(policy.pattern.matches(try MCPToolAddress.parse("tools.github.acme.main.write")) == false)
    }

    @Test func singleMidIsNotSegmentAnchored() throws {
        // Executable form of the pattern-story rule: `singleMid` is a
        // substring matcher whose middle may span segments, so it neither
        // implies nor is implied by one segment-anchored mid-`*`.
        let address = try MCPToolAddress.parse("tools.github.acme.main.x.read")
        #expect(ToolPattern.singleMid(prefix: "tools.github.", suffix: ".read").matches(address))
        #expect(try ToolPattern.parse("tools.github.*.read").matches(address) == false)
        #expect(try ToolPattern.parse("tools.github.*.*.*.read").matches(address))
    }

    @Test func singleMidDivergenceRule() throws {
        // Precise form of the divergence rule over valid addresses:
        // `singleMid(prefix, suffix)` and its one-mid-`*` translation agree
        // exactly when the middle is one dot-free segment. A multi-segment
        // middle matches only the legacy side. (The reverse direction —
        // segment-only hits on a degenerate empty middle — needs literals
        // outside the address grammar; see
        // `matches_midWildcardConsumesEmptyLiteralSegments`.)
        let legacy = ToolPattern.singleMid(prefix: "tools.a.b.", suffix: ".read")
        let anchored = try ToolPattern.parse("tools.a.b.*.read")
        let oneSegment = try MCPToolAddress.parse("tools.a.b.x.read")
        #expect(legacy.matches(oneSegment))
        #expect(anchored.matches(oneSegment))
        let twoSegments = try MCPToolAddress.parse("tools.a.b.x.y.read")
        #expect(legacy.matches(twoSegments))
        #expect(anchored.matches(twoSegments) == false)
        let neitherSide = try MCPToolAddress.parse("tools.a.b.x.write")
        #expect(legacy.matches(neitherSide) == false)
        #expect(anchored.matches(neitherSide) == false)
    }

    @Test func legacyStoredPayloadsDecodeWithFrozenBehavior() throws {
        // Stored-rule compat: blobs encoded by the pre-`segments` wire shape
        // decode under the new code with byte-identical legacy behavior.
        // Shapes captured from the base-commit encoder (key order varies by
        // process; decoding is order-insensitive).
        let address = try MCPToolAddress.parse("tools.github.acme.main.read")
        let blobs: [(String, ToolPattern)] = [
            (
                #"{"exact":{"_0":"tools.github.acme.main.read"}}"#,
                .exact(address)
            ),
            (#"{"any":{}}"#, .any),
            (
                #"{"trailingPrefix":{"_0":"tools.github."}}"#,
                .trailingPrefix("tools.github.")
            ),
            (
                #"{"singleMid":{"prefix":"tools.","suffix":".read"}}"#,
                .singleMid(prefix: "tools.", suffix: ".read")
            ),
        ]
        for (json, expected) in blobs {
            let decoded = try JSONDecoder().decode(
                ToolPattern.self,
                from: Data(json.utf8)
            )
            #expect(decoded == expected)
            #expect(decoded.matches(address) == expected.matches(address))
        }
    }
}

@Suite("SegmentPatternEdges")
struct SegmentPatternEdgesTests {
    // Adversarial and degenerate inputs: non-ASCII lookalikes, degenerate
    // literals, bare-dot rejections, infinite placement rows.

    @Test func matches_fullwidthMetacharsAreLiterals() throws {
        // Executor splits/compares on ASCII `.`/`*` only; fullwidth lookalikes
        // are literal text in both engines, never metacharacters.
        let star = try SegmentPattern.parse("a.\u{FF0A}")
        #expect(star == .exact(segments: ["a", "\u{FF0A}"]))
        #expect(star.matches(literal: "a.\u{FF0A}"))
        #expect(star.matches(literal: "a.b") == false)
        #expect(star.matches(literal: "a.whatever") == false)
        let stop = try SegmentPattern.parse("a\u{3002}b")
        #expect(stop == .exact(segments: ["a\u{3002}b"]))
        #expect(stop.matches(literal: "a\u{3002}b"))
        #expect(stop.matches(literal: "a.b") == false)
    }

    @Test func matches_midWildcardConsumesEmptyLiteralSegments() throws {
        // Verbatim Executor: the literal is split without validation, so a
        // mid-`*` consumes one segment that exists even when it is empty, and
        // a trailing `*` counts degenerate tails toward the subtree floor.
        #expect(try SegmentPattern.parse("a.*.b").matches(literal: "a..b"))
        #expect(try SegmentPattern.parse("a.*").matches(literal: "a."))
        #expect(try SegmentPattern.parse("a").matches(literal: "a.") == false)
    }

    @Test func parse_rejectsBareDots() {
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse("..")
        }
        #expect(throws: ToolPatternError.leadingDot) {
            try SegmentPattern.parse("...")
        }
    }

    @Test func position_infiniteRowsNeverTrap() throws {
        // Infinities saturate like `FractionalIndex.between`: below `-inf`
        // and above `+inf` are inexpressible, so the edge key ties the
        // extreme row instead of trapping.
        typealias Row = (id: String, pattern: SegmentPattern, position: FractionalIndex)
        let rows: [Row] = [
            (id: "a", pattern: try SegmentPattern.parse("a.b.c"), position: FractionalIndex(value: -.infinity)),
            (id: "b", pattern: try SegmentPattern.parse("a.*"), position: FractionalIndex(value: .infinity)),
        ]
        let above = SegmentPattern.positionForNewPattern(try SegmentPattern.parse("x.y.z.w"), rows: rows)
        #expect(above == FractionalIndex(value: -.infinity))
        let below = SegmentPattern.positionForNewPattern(try SegmentPattern.parse("*"), rows: rows)
        #expect(below == FractionalIndex(value: .infinity))
        let middle = SegmentPattern.positionForNewPattern(try SegmentPattern.parse("m.n"), rows: rows)
        #expect(middle == FractionalIndex(value: -.infinity))
    }

    @Test func parse_rejectsOverlongRawInput() {
        // 200KB of hostile input: rejected by the cap on every entry point.
        let huge = String(repeating: "a.", count: 100_000)
        #expect(huge.count == 200_000)
        #expect(throws: ToolPatternError.patternTooLong) {
            try SegmentPattern.parse(huge)
        }
        #expect(SegmentPattern.isValid(huge) == false)
        #expect(ToolPattern.isValid(huge) == false)
        #expect(throws: ToolPatternError.patternTooLong) {
            try ToolPattern.parse(huge)
        }
    }

    @Test func parse_lengthCapBoundary() throws {
        let ok = String(repeating: "a", count: SegmentPattern.maxRawCharacters)
        #expect(SegmentPattern.maxRawCharacters == 1024)
        #expect(try SegmentPattern.parse(ok) == .exact(segments: [ok]))
        #expect(throws: ToolPatternError.patternTooLong) {
            try SegmentPattern.parse(String(repeating: "a", count: SegmentPattern.maxRawCharacters + 1))
        }
        // The cap runs before the grammar: an over-long input reports length
        // however else it reads.
        #expect(throws: ToolPatternError.patternTooLong) {
            try SegmentPattern.parse("." + String(repeating: "a", count: SegmentPattern.maxRawCharacters))
        }
        #expect(throws: ToolPatternError.patternTooLong) {
            try SegmentPattern.parse(String(repeating: "a", count: SegmentPattern.maxRawCharacters + 1) + ".*")
        }
    }

    @Test func parse_newlineIsLiteralAndNeverMatches() throws {
        // No per-segment character checks (Executor parity): a newline parses
        // as literal text that no valid address can contain, so the pattern
        // is matchable only by the literal raw string itself, never by address.
        let pattern = try SegmentPattern.parse("tools.a\nb.c")
        #expect(pattern == .exact(segments: ["tools", "a\nb", "c"]))
        let address = try MCPToolAddress.parse("tools.a.user.main.x")
        #expect(pattern.matches(address) == false)
        #expect(pattern.matches(literal: "tools.a\nb.c") == true)
        #expect(ToolPattern.isValid("x\ny") == true)
    }
}

@Suite("ToolPatternMigration")
struct ToolPatternMigrationTests {
    @Test func migratedToSegments_exactShapes() throws {
        #expect(ToolPattern.any.migratedToSegments == .any)
        let segments = try SegmentPattern.parse("a.*.c")
        #expect(ToolPattern.segments(segments).migratedToSegments == segments)
        let address = try MCPToolAddress.parse("tools.github.user.main.repos.list")
        #expect(ToolPattern.exact(address).migratedToSegments == .exact(segments: ["tools", "github", "user", "main", "repos", "list"]))
        // An empty prefix matches everything, exactly like the universal.
        #expect(ToolPattern.trailingPrefix("").migratedToSegments == .any)
        // Prefixes migrate to subtree wildcards, never to exact.
        #expect(ToolPattern.trailingPrefix("tools.github.").migratedToSegments == .wildcard(segments: [.literal("tools"), .literal("github")], subtree: true))
        #expect(ToolPattern.trailingPrefix("tools.github").migratedToSegments == .wildcard(segments: [.literal("tools"), .literal("github")], subtree: true))
    }

    @Test func migratedToSegments_refusesNarrowing() {
        // singleMid is substring-based: its middle may span segments, so
        // every rendering narrows — refuse, however aligned it looks.
        #expect(ToolPattern.singleMid(prefix: "tools.a.", suffix: ".list").migratedToSegments == nil)
        #expect(ToolPattern.singleMid(prefix: "tools.", suffix: "").migratedToSegments == nil)
        #expect(ToolPattern.singleMid(prefix: "", suffix: "").migratedToSegments == nil)
        // A literal star would flip meaning under segments: refuse.
        #expect(ToolPattern.trailingPrefix("tools.*.").migratedToSegments == nil)
        #expect(ToolPattern.trailingPrefix("*").migratedToSegments == nil)
        // No segments left to anchor: refuse.
        #expect(ToolPattern.trailingPrefix(".").migratedToSegments == nil)
        #expect(ToolPattern.trailingPrefix("...").migratedToSegments == nil)
    }

    @Test func migratedToSegments_preservesEveryMatch() throws {
        // Migration never narrows: every address a legacy pattern matches,
        // its migrated form matches too. Refusals preserve vacuously.
        let addresses = try [
            "tools.github.user.main.repos.list",
            "tools.github.user.main.repos",
            "tools.github.org.ops.deploy",
            "tools.github.user.main.x",
            "tools.i.o.c.t",
            "tools.i.o.c.t.u",
            "tools.a.b.c.d",
            "tools.a.b.c.d.e.f",
            "tools.x.y.z.w",
            "tools.gitlab.user.ci.pipelines.run",
        ].map(MCPToolAddress.parse)
        let legacies: [ToolPattern] = [
            .any,
            .exact(addresses[0]),
            .exact(addresses[4]),
            .trailingPrefix(""),
            .trailingPrefix("tools."),
            .trailingPrefix("tools.github"),
            .trailingPrefix("tools.github."),
            .trailingPrefix("tools.i.o.c.t."),
            .trailingPrefix("tools.git"),
            .trailingPrefix("tools.a.b.c.d.e.f."),
            .trailingPrefix("tools.nomatch."),
            .trailingPrefix("."),
            .trailingPrefix("tools.*."),
            .singleMid(prefix: "tools.", suffix: ".list"),
            .singleMid(prefix: "tools.github.", suffix: ""),
            .singleMid(prefix: "", suffix: ""),
            .segments(try SegmentPattern.parse("a.*")),
        ]
        for legacy in legacies {
            guard let migrated = legacy.migratedToSegments else { continue }
            for address in addresses {
                if legacy.matches(address) {
                    #expect(migrated.matches(address), "\(legacy) lost \(address.literal)")
                }
            }
        }
    }

    @Test func migratedToSegments_trailingDotGainsBarePrefixOnly() throws {
        // The one documented widening: a trailing-dot prefix gains its bare
        // prefix (which the boundary rule excluded) and nothing else.
        let legacy = ToolPattern.trailingPrefix("tools.i.o.c.t.")
        let migrated = try #require(legacy.migratedToSegments)
        let bare = try MCPToolAddress.parse("tools.i.o.c.t")
        #expect(legacy.matches(bare) == false)
        #expect(migrated.matches(bare) == true)
        let deeper = try MCPToolAddress.parse("tools.i.o.c.t.u")
        #expect(legacy.matches(deeper) == true)
        #expect(migrated.matches(deeper) == true)
        let elsewhere = try MCPToolAddress.parse("tools.i.o.c.x")
        #expect(legacy.matches(elsewhere) == false)
        #expect(migrated.matches(elsewhere) == false)
    }
}
