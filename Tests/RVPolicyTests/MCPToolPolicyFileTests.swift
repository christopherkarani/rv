#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVFileStore
import Testing
@testable import RVPolicy

/// Strict owner-only loaders for `mcp-policies.json` and `mcp-toolkits.json`.
///
/// These loaders close the E2E-noted gap (no MCP policy file loader): every
/// shape or value violation fails closed, hostile JSON never yields rules,
/// and the read discipline mirrors `MCPIntegrationStore` (dir-fd, NOFOLLOW,
/// S_IFREG, owner-only) through the shared `OwnerOnlyFile` reader.
@Suite("MCP tool policy files")
struct MCPToolPolicyFileTests {
    // MARK: - Helpers

    private func policyRule(
        id: String = "p1",
        owner: String = "user",
        pattern: String = "tools.a.*",
        action: String = "block",
        position: String = "1.5"
    ) -> String {
        #"{"id":"\#(id)","owner":"\#(owner)","pattern":"\#(pattern)","action":"\#(action)","position":\#(position)}"#
    }

    private func policyDocument(_ rules: String, version: String = "1") -> Data {
        Data(#"{"version":\#(version),"policies":[\#(rules)]}"#.utf8)
    }

    private func toolkit(
        id: String = "tk1",
        owner: String = "org",
        slug: String = "deploy-kit",
        name: String = "Deploy Kit",
        policies: String = "",
        connections: String = ""
    ) -> String {
        #"{"id":"\#(id)","owner":"\#(owner)","slug":"\#(slug)","name":"\#(name)","policies":[\#(policies)],"connections":[\#(connections)]}"#
    }

    private func toolkitRule(
        id: String = "p1", pattern: String = "tools.a.*", action: String = "block", position: String = "1.5"
    ) -> String {
        #"{"id":"\#(id)","pattern":"\#(pattern)","action":"\#(action)","position":\#(position)}"#
    }

    private func toolkitGrant(id: String = "c1", pattern: String = "tools.a.*", position: String = "0") -> String {
        #"{"id":"\#(id)","pattern":"\#(pattern)","position":\#(position)}"#
    }

    private func toolkitDocument(_ toolkits: String, version: String = "1") -> Data {
        Data(#"{"version":\#(version),"toolkits":[\#(toolkits)]}"#.utf8)
    }

    private func problems(_ found: [(index: Int, reason: String)]) -> [String] {
        found.map { "\($0.index):\($0.reason)" }
    }

    private func segments(_ raw: String) throws -> SegmentPattern {
        try SegmentPattern.parse(raw)
    }

    private func filePolicy(
        id: String = "p1",
        pattern: String = "tools.a.*",
        position: Double = 1.5
    ) throws -> MCPFilePolicy {
        MCPFilePolicy(
            id: id, owner: .user, pattern: try segments(pattern), action: .block,
            position: FractionalIndex(value: position)
        )
    }

    // MARK: - mcp-policies.json decode

    @Test func policiesDecodeFullDocument() throws {
        let data = policyDocument(
            policyRule()
                + ","
                + policyRule(id: "p2", owner: "org", pattern: "tools.b.c", action: "require_approval", position: "2")
                + ","
                + policyRule(id: "p3", owner: "org", pattern: "*", action: "approve", position: "-3")
        )
        let decoded = try MCPToolPolicyFile.decode(data).get()
        #expect(decoded.count == 3)
        let expectedPattern = try segments("tools.a.*")
        #expect(decoded[0].pattern == expectedPattern)
        #expect(decoded[1] == MCPFilePolicy(
            id: "p2", owner: .org, pattern: try segments("tools.b.c"), action: .requireApproval,
            position: FractionalIndex(value: 2)
        ))
        #expect(decoded[2].pattern == .any)
        #expect(MCPToolPolicyFile.validate(data).isEmpty)
    }

    @Test func policiesDecodeEmptyList() throws {
        let decoded = try MCPToolPolicyFile.decode(policyDocument("")).get()
        #expect(decoded.isEmpty)
    }

    @Test func policiesRejectDuplicateIDs() throws {
        let data = policyDocument(policyRule(id: "p") + "," + policyRule(id: "p"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(data).get() }
        #expect(problems(MCPToolPolicyFile.validate(data)) == ["1:duplicateID"])
    }

    @Test func policiesRejectBadVersions() {
        #expect(throws: MCPToolPolicyFileError.unsupportedVersion) {
            try MCPToolPolicyFile.decode(self.policyDocument("", version: "2")).get()
        }
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.decode(self.policyDocument("", version: #""1""#)).get()
        }
        #expect(self.problems(MCPToolPolicyFile.validate(self.policyDocument("", version: "0"))) == ["-1:unsupportedVersion"])
    }

    @Test func policiesRejectMalformedDocuments() {
        for text in ["", "{", "[]", "null", "{}", #"{"version":1}"#, #"{"policies":[]}"#] {
            let data = Data(text.utf8)
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolPolicyFile.decode(data).get()
            }
            #expect(problems(MCPToolPolicyFile.validate(data)) == ["-1:invalidDocument"])
        }
    }

    @Test func policiesRejectUnknownKeysAtEveryLevel() {
        let withDocKey = Data(#"{"version":1,"policies":[],"smuggled":true}"#.utf8)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(withDocKey).get() }
        let rule = #"{"id":"p","owner":"user","pattern":"tools.a.*","action":"block","position":1,"secret":"x"}"#
        let withRuleKey = policyDocument(rule)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(withRuleKey).get() }
        #expect(problems(MCPToolPolicyFile.validate(withRuleKey)) == ["-1:invalidDocument"])
    }

    @Test func policiesRejectWrongTypesAndNulls() {
        let cases = [
            #"{"id":1,"owner":"user","pattern":"tools.a.*","action":"block","position":1}"#,
            #"{"id":"p","owner":"user","pattern":"tools.a.*","action":"block","position":"1"}"#,
            #"{"id":null,"owner":"user","pattern":"tools.a.*","action":"block","position":1}"#,
            #"{"id":"p","owner":"user","pattern":"tools.a.*","action":"block"}"#,
            #"{"id":"p","owner":"user","pattern":"tools.a.*","action":"block","position":1.5,""#,
        ]
        for rule in cases {
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolPolicyFile.decode(self.policyDocument(rule)).get()
            }
        }
        let notArray = Data(#"{"version":1,"policies":{}}"#.utf8)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(notArray).get() }
    }

    @Test func policiesRejectBadFieldValues() {
        let cases: [(rule: String, reason: String)] = [
            (policyRule(id: ""), "id"),
            (policyRule(id: #"a\u0000b"#), "id"),
            (policyRule(owner: "ORG"), "owner"),
            (policyRule(owner: "admin"), "owner"),
            (policyRule(pattern: "tools..bad"), "pattern"),
            (policyRule(pattern: "*bogus"), "pattern"),
            (policyRule(pattern: String(repeating: "a", count: 2000)), "pattern"),
            (policyRule(action: "allow"), "action"),
            (policyRule(action: "requireApproval"), "action"),
        ]
        for (rule, reason) in cases {
            let data = policyDocument(rule)
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolPolicyFile.decode(data).get()
            }
            #expect(problems(MCPToolPolicyFile.validate(data)) == ["0:\(reason)"])
        }
    }

    @Test func policiesRejectControlAndFormatIDs() {
        // JSON escapes decode before validation: NUL, newline, and zero-width
        // space in ids all fail closed through the identifier allow-list.
        for escaped in [#"a\u0000b"#, #"a\nb"#, #"a\u200Bb"#] {
            let data = policyDocument(#"{"id":"\#(escaped)","owner":"user","pattern":"tools.a.*","action":"block","position":1}"#)
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolPolicyFile.decode(data).get()
            }
        }
    }

    @Test func policiesEnforceIDCharset() throws {
        // Sibling identifier charset: ASCII letters, digits, `-`, `.`, `_`.
        // Anything else — spaces, path separators, `mcp:`-shaped prefixes,
        // emoji — fails closed with the field label.
        for id in ["p 1", "a/b", "mcp:x", "p🔥", "a:b", "trailing!", "semi;colon"] {
            let data = policyDocument(policyRule(id: id))
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolPolicyFile.decode(data).get()
            }
            #expect(problems(MCPToolPolicyFile.validate(data)) == ["0:id"])
        }
        for id in ["p1", "POL_9.x-y_z", UUID().uuidString, "pol_k3j8s9abc123", "a.b_c-d"] {
            let data = policyDocument(policyRule(id: id))
            #expect(try MCPToolPolicyFile.decode(data).get().count == 1)
            #expect(MCPToolPolicyFile.validate(data).isEmpty)
        }
    }

    @Test func policiesRejectInfinitePositions() {
        // 1e999 overflows Double: the DTO decode throws, so infinity (and
        // NaN, unrepresentable in JSON numbers) can never enter a loaded
        // rule — the `FractionalIndex` NaN trap stays unreachable.
        let data = policyDocument(policyRule(position: "1e999"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(data).get() }
        #expect(problems(MCPToolPolicyFile.validate(data)) == ["-1:invalidDocument"])
        let toolkitData = toolkitDocument(toolkit(policies: toolkitRule(position: "-1e999")))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(toolkitData).get() }
    }

    @Test func policiesEnforceIDLength() throws {
        let ok = policyDocument(policyRule(id: String(repeating: "a", count: 128)))
        #expect(try MCPToolPolicyFile.decode(ok).get().count == 1)
        let tooLong = policyDocument(policyRule(id: String(repeating: "a", count: 129)))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(tooLong).get() }
        #expect(problems(MCPToolPolicyFile.validate(tooLong)) == ["0:id"])
    }

    @Test func policiesEnforcePatternLength() throws {
        let okPattern = "tools." + String(repeating: "a", count: 1018)
        #expect(okPattern.count == 1024)
        let ok = policyDocument(policyRule(pattern: okPattern))
        #expect(try MCPToolPolicyFile.decode(ok).get().count == 1)
        let tooLong = policyDocument(policyRule(pattern: okPattern + "a"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(tooLong).get() }
    }

    @Test func policiesEnforceRuleCap() throws {
        var rules: [String] = []
        for index in 0..<256 {
            rules.append(policyRule(id: "p\(index)", position: "\(index)"))
        }
        #expect(try MCPToolPolicyFile.decode(policyDocument(rules.joined(separator: ","))).get().count == 256)
        rules.append(policyRule(id: "overflow", position: "999"))
        let over = policyDocument(rules.joined(separator: ","))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.decode(over).get() }
        #expect(problems(MCPToolPolicyFile.validate(over)) == ["-1:tooManyPolicies"])
    }

    @Test func policiesRejectOversizedInput() {
        let data = Data(repeating: 0x7B, count: MCPToolPolicyFile.maximumBytes + 1)
        #expect(throws: MCPToolPolicyFileError.oversized) { try MCPToolPolicyFile.decode(data).get() }
        #expect(problems(MCPToolPolicyFile.validate(data)) == ["-1:oversized"])
    }

    // MARK: - mcp-policies.json encode

    @Test func policiesEncodeCanonicalRoundTrip() throws {
        let policies = [
            MCPFilePolicy(
                id: "p1", owner: .user, pattern: try segments("tools.a.*"), action: .block,
                position: FractionalIndex(value: 1.5)
            ),
            MCPFilePolicy(
                id: "p2", owner: .org, pattern: try segments("*"), action: .approve,
                position: FractionalIndex(value: -2)
            ),
        ]
        let bytes = try MCPToolPolicyFile.encode(policies).get()
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"policies":[{"action":"block","id":"p1","owner":"user","pattern":"tools.a.*","position":1.5},{"action":"approve","id":"p2","owner":"org","pattern":"*","position":-2}],"version":1}"#)
        #expect(try MCPToolPolicyFile.decode(bytes).get() == policies)
    }

    @Test func policiesEncodeEmptyList() throws {
        let bytes = try MCPToolPolicyFile.encode([]).get()
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"policies":[],"version":1}"#)
    }

    @Test func policiesEncodeRejectsDuplicateIDs() throws {
        // Like `decode`: encoded bytes must always decode.
        let first = try filePolicy(id: "dup")
        let second = try filePolicy(id: "dup")
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.encode([first, second]).get()
        }
        let distinct = try MCPToolPolicyFile.encode([first, try filePolicy(id: "other")]).get()
        #expect(try MCPToolPolicyFile.decode(distinct).get().count == 2)
    }

    @Test func fileEncodeRejectsBadCharsetIDs() throws {
        let pattern = try segments("tools.a.*")
        let badPolicy = MCPFilePolicy(
            id: "not an id", owner: .user, pattern: pattern, action: .block,
            position: FractionalIndex(value: 0)
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.encode([badPolicy]).get()
        }
        let badToolkit = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [
                MCPFileToolkitPolicy(
                    id: "a/b", pattern: pattern, action: .block, position: FractionalIndex(value: 0)
                )
            ],
            connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolkitFile.encode([badToolkit]).get()
        }
    }

    @Test func policiesEncodeRejectsInvalidModels() throws {
        let badID = try filePolicy(id: "")
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.encode([badID]).get() }
        let badPosition = MCPFilePolicy(
            id: "p", owner: .user, pattern: try segments("tools.a.*"), action: .block,
            position: FractionalIndex(value: .infinity)
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.encode([badPosition]).get()
        }
        let good = try filePolicy()
        let tooMany = Array(repeating: good, count: MCPToolPolicyFile.maximumPolicies + 1)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolPolicyFile.encode(tooMany).get() }
    }

    @Test func policiesEncodeRejectsOverlongIDs() throws {
        // The 128B id cap binds hand-built models exactly like decoded bytes.
        let ok = try filePolicy(id: String(repeating: "a", count: 128))
        let roundTripped = try MCPToolPolicyFile.decode(try MCPToolPolicyFile.encode([ok]).get()).get()
        #expect(roundTripped == [ok])
        let tooLong = try filePolicy(id: String(repeating: "a", count: 129))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.encode([tooLong]).get()
        }
    }

    @Test func policiesEncodeRejectsOversizedOutput() throws {
        // 256 rules at the 1024-char pattern cap overflow the 64KB read cap.
        let bigPattern = try segments("tools." + String(repeating: "a", count: 1018))
        var rules: [MCPFilePolicy] = []
        for index in 0..<MCPToolPolicyFile.maximumPolicies {
            rules.append(MCPFilePolicy(
                id: "p\(index)", owner: .user, pattern: bigPattern, action: .block,
                position: FractionalIndex(value: Double(index))
            ))
        }
        #expect(throws: MCPToolPolicyFileError.oversized) { try MCPToolPolicyFile.encode(rules).get() }
    }

    // MARK: - mcp-toolkits.json decode

    @Test func toolkitsDecodeFullDocument() throws {
        let data = toolkitDocument(
            toolkit(policies: toolkitRule() + "," + toolkitRule(id: "p2", action: "approve"), connections: toolkitGrant())
                + ","
                + toolkit(id: "tk2", owner: "user", slug: "me-kit", name: "Me")
        )
        let decoded = try MCPToolkitFile.decode(data).get()
        #expect(decoded.count == 2)
        #expect(decoded[0].slug == "deploy-kit")
        #expect(decoded[0].policies.count == 2)
        #expect(decoded[0].connections.count == 1)
        #expect(decoded[1].policies.isEmpty && decoded[1].connections.isEmpty)
        #expect(MCPToolkitFile.validate(data).isEmpty)
    }

    @Test func toolkitsDecodeEmptyList() throws {
        #expect(try MCPToolkitFile.decode(toolkitDocument("")).get().isEmpty)
    }

    @Test func toolkitsRejectDuplicateIDsAndSlugs() {
        let dupID = toolkitDocument(toolkit(id: "tk") + "," + toolkit(id: "tk", slug: "other"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(dupID).get() }
        #expect(problems(MCPToolkitFile.validate(dupID)) == ["1:duplicateID"])
        let dupSlug = toolkitDocument(toolkit() + "," + toolkit(id: "tk2", slug: "deploy-kit"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(dupSlug).get() }
        #expect(problems(MCPToolkitFile.validate(dupSlug)) == ["1:duplicateSlug"])
    }

    @Test func toolkitsRejectBadVersionsAndShapes() {
        #expect(throws: MCPToolPolicyFileError.unsupportedVersion) {
            try MCPToolkitFile.decode(self.toolkitDocument("", version: "2")).get()
        }
        for text in ["", "{", "[]", "null", #"{"version":1}"#, #"{"version":1,"toolkits":{}}"#] {
            let data = Data(text.utf8)
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolkitFile.decode(data).get()
            }
            #expect(problems(MCPToolkitFile.validate(data)) == ["-1:invalidDocument"])
        }
        #expect(problems(MCPToolkitFile.validate(toolkitDocument("", version: "9"))) == ["-1:unsupportedVersion"])
    }

    @Test func toolkitsRejectUnknownKeysAtEveryLevel() {
        let levels = [
            #"{"version":1,"toolkits":[],"x":1}"#,
            #"{"version":1,"toolkits":[{"id":"t","owner":"org","slug":"s","name":"n","policies":[],"connections":[],"x":1}]}"#,
            #"{"version":1,"toolkits":[{"id":"t","owner":"org","slug":"s","name":"n","policies":[{"id":"p","pattern":"tools.a.*","action":"block","position":1,"x":1}],"connections":[]}]}"#,
            #"{"version":1,"toolkits":[{"id":"t","owner":"org","slug":"s","name":"n","policies":[],"connections":[{"id":"c","pattern":"tools.a.*","position":1,"x":1}]}]}"#,
        ]
        for text in levels {
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolkitFile.decode(Data(text.utf8)).get()
            }
        }
    }

    @Test func toolkitsRejectBadScalarFields() {
        let cases: [(text: String, reason: String)] = [
            (toolkit(id: ""), "id"),
            (toolkit(owner: "ORG"), "owner"),
            (toolkit(owner: "admin"), "owner"),
            (toolkit(slug: ""), "slug"),
            (toolkit(slug: "-bad-"), "slug"),
            (toolkit(slug: "ab-"), "slug"),
            (toolkit(slug: "has_underscore"), "slug"),
            (toolkit(slug: "UPPER"), "slug"),
            (toolkit(slug: String(repeating: "a", count: 64)), "slug"),
            (toolkit(slug: "has space"), "slug"),
            (toolkit(slug: "kit-🔥"), "slug"),
            (toolkit(name: ""), "name"),
            (toolkit(name: String(repeating: "a", count: 257)), "name"),
            (toolkit(name: #"a\nb"#), "name"),
        ]
        for (text, reason) in cases {
            let data = toolkitDocument(text)
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolkitFile.decode(data).get()
            }
            #expect(problems(MCPToolkitFile.validate(data)) == ["0:\(reason)"])
        }
    }

    @Test func toolkitsAcceptScalarBoundaries() throws {
        let boundary = toolkit(
            id: String(repeating: "i", count: 128),
            slug: String(repeating: "s", count: 63),
            name: String(repeating: "n", count: 256)
        )
        #expect(try MCPToolkitFile.decode(toolkitDocument(boundary)).get().count == 1)
    }

    @Test func toolkitsEnforceIDCharset() throws {
        // Toolkit ids.
        let badToolkit = toolkitDocument(toolkit(id: "not an id"))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(badToolkit).get() }
        #expect(problems(MCPToolkitFile.validate(badToolkit)) == ["0:id"])
        // Nested policy ids.
        let badPolicy = toolkitDocument(toolkit(policies: toolkitRule(id: "a/b")))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(badPolicy).get() }
        #expect(problems(MCPToolkitFile.validate(badPolicy)) == ["0:policies[0].id"])
        // Nested connection ids.
        let badGrant = toolkitDocument(toolkit(connections: toolkitGrant(id: "mcp:x")))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(badGrant).get() }
        #expect(problems(MCPToolkitFile.validate(badGrant)) == ["0:connections[0].id"])
        // Executor- and UUID-shaped ids pass at every level.
        let good = toolkitDocument(toolkit(
            id: UUID().uuidString,
            policies: toolkitRule(id: "pol_k3j8s9abc123"),
            connections: toolkitGrant(id: "tkconn_a1.b-2_c")
        ))
        #expect(try MCPToolkitFile.decode(good).get().count == 1)
        #expect(MCPToolkitFile.validate(good).isEmpty)
        // Over the byte cap fails at every level.
        let longToolkit = toolkitDocument(toolkit(id: String(repeating: "i", count: 129)))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(longToolkit).get() }
        #expect(problems(MCPToolkitFile.validate(longToolkit)) == ["0:id"])
        let longRule = toolkitDocument(toolkit(policies: toolkitRule(id: String(repeating: "p", count: 129))))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(longRule).get() }
        #expect(problems(MCPToolkitFile.validate(longRule)) == ["0:policies[0].id"])
        let longGrant = toolkitDocument(toolkit(connections: toolkitGrant(id: String(repeating: "c", count: 129))))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(longGrant).get() }
        #expect(problems(MCPToolkitFile.validate(longGrant)) == ["0:connections[0].id"])
    }

    @Test func toolkitsRejectBadNestedRules() {
        let cases: [(policies: String, connections: String, reason: String)] = [
            (toolkitRule(id: ""), "", "policies[0].id"),
            (toolkitRule(pattern: "tools..bad"), "", "policies[0].pattern"),
            (toolkitRule(action: "allow"), "", "policies[0].action"),
            ("", toolkitGrant(id: ""), "connections[0].id"),
            ("", toolkitGrant(pattern: "tools..bad"), "connections[0].pattern"),
            (
                toolkitRule(id: "a") + "," + toolkitRule(id: "b", pattern: "tools.b.*") + "," + toolkitRule(id: "a", pattern: "tools.c.*"),
                "",
                "policies[2].duplicateID"
            ),
            ("", toolkitGrant(id: "a") + "," + toolkitGrant(id: "a", pattern: "tools.b.*"), "connections[1].duplicateID"),
            (toolkitRule(id: "shared"), toolkitGrant(id: "shared"), "connections[0].duplicateID"),
        ]
        for (index, entry) in cases.enumerated() {
            let data = toolkitDocument(toolkit(policies: entry.policies, connections: entry.connections))
            #expect(throws: MCPToolPolicyFileError.invalidDocument) {
                try MCPToolkitFile.decode(data).get()
            }
            #expect(problems(MCPToolkitFile.validate(data)) == ["0:\(entry.reason)"], "case \(index)")
        }
    }

    @Test func toolkitsEnforceNestedCaps() {
        var rules: [String] = []
        for index in 0...MCPToolkitFile.maximumPolicies {
            rules.append(toolkitRule(id: "p\(index)"))
        }
        let overPolicies = toolkitDocument(toolkit(policies: rules.joined(separator: ",")))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(overPolicies).get() }
        #expect(problems(MCPToolkitFile.validate(overPolicies)) == ["0:policies"])
        var grants: [String] = []
        for index in 0...MCPToolkitFile.maximumConnections {
            grants.append(toolkitGrant(id: "c\(index)"))
        }
        let overConnections = toolkitDocument(toolkit(connections: grants.joined(separator: ",")))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(overConnections).get() }
        #expect(problems(MCPToolkitFile.validate(overConnections)) == ["0:connections"])
    }

    @Test func toolkitsEnforceFileCap() throws {
        var entries: [String] = []
        for index in 0..<MCPToolkitFile.maximumToolkits {
            entries.append(toolkit(id: "tk\(index)", slug: "kit-\(index)", name: "Kit \(index)"))
        }
        #expect(try MCPToolkitFile.decode(toolkitDocument(entries.joined(separator: ","))).get().count == 64)
        entries.append(toolkit(id: "overflow", slug: "overflow", name: "Overflow"))
        let over = toolkitDocument(entries.joined(separator: ","))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(over).get() }
        #expect(problems(MCPToolkitFile.validate(over)) == ["-1:tooManyToolkits"])
    }

    @Test func toolkitsRejectOversizedInput() {
        let data = Data(repeating: 0x7B, count: MCPToolkitFile.maximumBytes + 1)
        #expect(throws: MCPToolPolicyFileError.oversized) { try MCPToolkitFile.decode(data).get() }
        #expect(problems(MCPToolkitFile.validate(data)) == ["-1:oversized"])
    }

    // MARK: - mcp-toolkits.json encode

    @Test func toolkitsEncodeCanonicalRoundTrip() throws {
        let toolkits = [
            MCPFileToolkit(
                id: "tk1", owner: .org, slug: "deploy-kit", name: "Deploy Kit",
                policies: [
                    MCPFileToolkitPolicy(
                        id: "p1", pattern: try segments("tools.a.*"), action: .block,
                        position: FractionalIndex(value: 1)
                    )
                ],
                connections: [
                    MCPFileToolkitConnection(
                        id: "c1", pattern: try segments("tools.a.*"), position: FractionalIndex(value: 0)
                    )
                ]
            )
        ]
        let bytes = try MCPToolkitFile.encode(toolkits).get()
        #expect(try MCPToolkitFile.decode(bytes).get() == toolkits)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix(#"{"toolkits":[{"connections":[{"id":"c1""#))
        #expect(text.hasSuffix(#""version":1}"#))
    }

    @Test func toolkitsEncodeEmpty() throws {
        #expect(String(decoding: try MCPToolkitFile.encode([]).get(), as: UTF8.self) == #"{"toolkits":[],"version":1}"#)
    }

    @Test func toolkitsEncodeRejectsOversizedOutput() throws {
        // One toolkit at the nested caps with max-length patterns overflows 64KB.
        let bigPattern = try segments("tools." + String(repeating: "a", count: 1018))
        var policies: [MCPFileToolkitPolicy] = []
        for index in 0..<MCPToolkitFile.maximumPolicies {
            policies.append(MCPFileToolkitPolicy(
                id: "p\(index)", pattern: bigPattern, action: .block,
                position: FractionalIndex(value: Double(index))
            ))
        }
        let big = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: policies, connections: []
        )
        #expect(throws: MCPToolPolicyFileError.oversized) { try MCPToolkitFile.encode([big]).get() }
    }

    @Test func toolkitsEncodeRejectsInvalidModels() throws {
        let valid = MCPFileToolkit(id: "tk", owner: .org, slug: "kit", name: "Kit", policies: [], connections: [])
        let badID = MCPFileToolkit(id: "", owner: .org, slug: "kit", name: "Kit", policies: [], connections: [])
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([badID]).get() }
        let badSlug = MCPFileToolkit(id: "tk", owner: .org, slug: "BAD", name: "Kit", policies: [], connections: [])
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([badSlug]).get() }
        let badName = MCPFileToolkit(id: "tk", owner: .org, slug: "kit", name: "", policies: [], connections: [])
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([badName]).get() }
        let dupID = MCPFileToolkit(id: "tk", owner: .user, slug: "other", name: "Other", policies: [], connections: [])
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([valid, dupID]).get() }
        let dupSlug = MCPFileToolkit(id: "tk2", owner: .user, slug: "kit", name: "Other", policies: [], connections: [])
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([valid, dupSlug]).get() }
        let tooMany = Array(repeating: valid, count: MCPToolkitFile.maximumToolkits + 1)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode(tooMany).get() }
    }

    @Test func toolkitsEncodeRejectsInvalidNestedModels() throws {
        let pattern = try segments("tools.a.*")
        let badRuleID = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [MCPFileToolkitPolicy(id: "", pattern: pattern, action: .block, position: FractionalIndex(value: 0))],
            connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([badRuleID]).get() }
        let badPosition = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [],
            connections: [MCPFileToolkitConnection(id: "c", pattern: pattern, position: FractionalIndex(value: .infinity))]
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([badPosition]).get() }
        let rule = MCPFileToolkitPolicy(id: "dup", pattern: pattern, action: .block, position: FractionalIndex(value: 0))
        let dupRules = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [rule, rule], connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([dupRules]).get() }
        let grant = MCPFileToolkitConnection(id: "dup", pattern: pattern, position: FractionalIndex(value: 0))
        let dupGrants = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [], connections: [grant, grant]
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([dupGrants]).get() }
        let crossDup = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [rule], connections: [grant]
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([crossDup]).get() }
        let manyRules = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: Array(repeating: rule, count: MCPToolkitFile.maximumPolicies + 1), connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([manyRules]).get() }
        let manyGrants = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [], connections: Array(repeating: grant, count: MCPToolkitFile.maximumConnections + 1)
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.encode([manyGrants]).get() }
    }

    @Test func toolkitsEncodeRejectsOverlongIDs() throws {
        // The 128B id cap binds hand-built models at every level, exactly
        // like decoded bytes.
        let pattern = try segments("tools.a.*")
        let goodRule = MCPFileToolkitPolicy(
            id: String(repeating: "p", count: 128), pattern: pattern, action: .block,
            position: FractionalIndex(value: 0)
        )
        let goodGrant = MCPFileToolkitConnection(
            id: String(repeating: "c", count: 128), pattern: pattern, position: FractionalIndex(value: 0)
        )
        let good = MCPFileToolkit(
            id: String(repeating: "i", count: 128), owner: .org, slug: "kit", name: "Kit",
            policies: [goodRule], connections: [goodGrant]
        )
        #expect(try MCPToolkitFile.decode(try MCPToolkitFile.encode([good]).get()).get() == [good])
        let badToolkitID = MCPFileToolkit(
            id: String(repeating: "i", count: 129), owner: .org, slug: "kit", name: "Kit",
            policies: [], connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolkitFile.encode([badToolkitID]).get()
        }
        let badRuleID = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [
                MCPFileToolkitPolicy(
                    id: String(repeating: "p", count: 129), pattern: pattern, action: .block,
                    position: FractionalIndex(value: 0)
                )
            ],
            connections: []
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolkitFile.encode([badRuleID]).get()
        }
        let badGrantID = MCPFileToolkit(
            id: "tk", owner: .org, slug: "kit", name: "Kit",
            policies: [],
            connections: [
                MCPFileToolkitConnection(
                    id: String(repeating: "c", count: 129), pattern: pattern,
                    position: FractionalIndex(value: 0)
                )
            ]
        )
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolkitFile.encode([badGrantID]).get()
        }
    }

    @Test func toolkitsEnforceNameByteCap() throws {
        // The 256 name cap counts UTF-8 bytes, not characters: 128 two-byte
        // chars fit, 129 do not.
        let ok = toolkitDocument(toolkit(name: String(repeating: "é", count: 128)))
        #expect(try MCPToolkitFile.decode(ok).get().count == 1)
        let tooLong = toolkitDocument(toolkit(name: String(repeating: "é", count: 129)))
        #expect(throws: MCPToolPolicyFileError.invalidDocument) { try MCPToolkitFile.decode(tooLong).get() }
        #expect(problems(MCPToolkitFile.validate(tooLong)) == ["0:name"])
    }

    // MARK: - Owner-only loads

    private func freshDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-tool-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    private func writeOwnerOnly(_ data: Data, named fileName: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @Test func policiesLoadMissingFileAsEmpty() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try MCPToolPolicyFile.load(from: directory).get().isEmpty)
        let missingDir = directory.appendingPathComponent("no-such-dir", isDirectory: true)
        #expect(try MCPToolPolicyFile.load(from: missingDir).get().isEmpty)
    }

    @Test func toolkitsLoadMissingFileAsEmpty() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try MCPToolkitFile.load(from: directory).get().isEmpty)
    }

    @Test func policiesLoadRoundTripsOwnerOnlyFile() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = policyDocument(policyRule())
        try writeOwnerOnly(data, named: MCPToolPolicyFile.fileName, in: directory)
        let loaded = try MCPToolPolicyFile.load(from: directory).get()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "p1")
    }

    @Test func toolkitsLoadRoundTripsOwnerOnlyFile() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = toolkitDocument(toolkit())
        try writeOwnerOnly(data, named: MCPToolkitFile.fileName, in: directory)
        #expect(try MCPToolkitFile.load(from: directory).get().count == 1)
    }

    @Test func loadsRejectInvalidContent() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeOwnerOnly(Data("not json".utf8), named: MCPToolPolicyFile.fileName, in: directory)
        try writeOwnerOnly(Data("not json".utf8), named: MCPToolkitFile.fileName, in: directory)
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolPolicyFile.load(from: directory).get()
        }
        #expect(throws: MCPToolPolicyFileError.invalidDocument) {
            try MCPToolkitFile.load(from: directory).get()
        }
    }

    @Test func loadsRejectGroupReadableFiles() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policiesURL = directory.appendingPathComponent(MCPToolPolicyFile.fileName)
        try policyDocument(policyRule()).write(to: policiesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: policiesURL.path)
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolPolicyFile.load(from: directory).get()
        }
        let toolkitsURL = directory.appendingPathComponent(MCPToolkitFile.fileName)
        try toolkitDocument(toolkit()).write(to: toolkitsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: toolkitsURL.path)
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolkitFile.load(from: directory).get()
        }
    }

    @Test func loadsRejectSymlinkedFiles() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real.json")
        try policyDocument(policyRule()).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(MCPToolPolicyFile.fileName), withDestinationURL: target
        )
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolPolicyFile.load(from: directory).get()
        }
    }

    @Test func loadsRejectSymlinkedDirectories() throws {
        let base = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try writeOwnerOnly(policyDocument(policyRule()), named: MCPToolPolicyFile.fileName, in: base)
        try writeOwnerOnly(toolkitDocument(toolkit()), named: MCPToolkitFile.fileName, in: base)
        let link = base.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base)
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolPolicyFile.load(from: link).get()
        }
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolkitFile.load(from: link).get()
        }
    }

    @Test func loadsRejectGroupWritableDirectories() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeOwnerOnly(policyDocument(policyRule()), named: MCPToolPolicyFile.fileName, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: directory.path)
        #expect(throws: MCPToolPolicyFileError.unsafeLocation) {
            try MCPToolPolicyFile.load(from: directory).get()
        }
    }

    @Test func loadsRejectOversizedFiles() throws {
        let directory = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = Data(repeating: 0x7B, count: MCPToolPolicyFile.maximumBytes + 1)
        try writeOwnerOnly(big, named: MCPToolPolicyFile.fileName, in: directory)
        try writeOwnerOnly(big, named: MCPToolkitFile.fileName, in: directory)
        #expect(throws: MCPToolPolicyFileError.oversized) {
            try MCPToolPolicyFile.load(from: directory).get()
        }
        #expect(throws: MCPToolPolicyFileError.oversized) {
            try MCPToolkitFile.load(from: directory).get()
        }
    }

    @Test func loadFailureMappingCoversEveryArm() {
        #expect(MCPToolPolicyFile.mapLoadFailure(.missing) == .success([]))
        #expect(MCPToolPolicyFile.mapLoadFailure(.inaccessible) == .failure(.unsafeLocation))
        #expect(MCPToolPolicyFile.mapLoadFailure(.unsafeLocation) == .failure(.unsafeLocation))
        #expect(MCPToolPolicyFile.mapLoadFailure(.unreadable) == .failure(.unreadable))
        #expect(MCPToolPolicyFile.mapLoadFailure(.oversized) == .failure(.oversized))
        #expect(MCPToolkitFile.mapLoadFailure(.missing) == .success([]))
        #expect(MCPToolkitFile.mapLoadFailure(.inaccessible) == .failure(.unsafeLocation))
        #expect(MCPToolkitFile.mapLoadFailure(.unsafeLocation) == .failure(.unsafeLocation))
        #expect(MCPToolkitFile.mapLoadFailure(.unreadable) == .failure(.unreadable))
        #expect(MCPToolkitFile.mapLoadFailure(.oversized) == .failure(.oversized))
    }
}