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
