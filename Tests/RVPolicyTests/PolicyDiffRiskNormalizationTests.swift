import Testing
@testable import RVPolicy

@Suite("PolicyDiffRisk address normalization (F3)")
struct PolicyDiffRiskNormalizationTests {
    @Test func v4UnspecifiedDottedQuadIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("0.0.0.0"))
        #expect(PolicyDiffRisk.normalize("0.0.0.0")?.canonical == "0.0.0.0")
    }

    @Test func v4UnspecifiedNonzeroHostIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("0.1.2.3"))
        #expect(PolicyDiffRisk.normalize("0.1.2.3")?.bytes == [0, 1, 2, 3])
    }

    @Test func v6UnspecifiedCompressedIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::"))
        #expect(PolicyDiffRisk.normalize("::")?.canonical == "::")
    }

    @Test func v6UnspecifiedExpandedIsSensitive() {
        let normalized = PolicyDiffRisk.normalize("0:0:0:0:0:0:0:0")
        #expect(normalized?.canonical == "::")
        #expect(PolicyDiffRisk.isSensitive("0:0:0:0:0:0:0:0"))
    }

    @Test func v6UnspecifiedLeadingZerosIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("0000:0000:0000:0000:0000:0000:0000:0000"))
        #expect(
            PolicyDiffRisk.normalize("0000:0000:0000:0000:0000:0000:0000:0000")?.canonical == "::"
        )
    }

    @Test func mappedLoopbackIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::ffff:127.0.0.1"))
        #expect(PolicyDiffRisk.normalize("::ffff:127.0.0.1")?.canonical == "::ffff:127.0.0.1")
    }

    @Test func mappedUnspecifiedIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::ffff:0.0.0.0"))
        #expect(PolicyDiffRisk.isSensitive("::ffff:0.1.2.3"))
    }

    @Test func mappedPrivateIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::ffff:10.0.0.1"))
        #expect(PolicyDiffRisk.isSensitive("::ffff:192.168.1.1"))
        #expect(PolicyDiffRisk.isSensitive("::ffff:172.16.0.1"))
    }

    @Test func compatibleLoopbackIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::127.0.0.1"))
    }

    @Test func compatiblePrivateIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::10.0.0.1"))
    }

    @Test func sixToFourLoopbackIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("2002:7f00:1::"))
    }

    @Test func sixToFourPrivateIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("2002:0a00:0001::"))
    }

    @Test func bracketedUnspecifiedIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("[::]"))
        #expect(PolicyDiffRisk.normalize("[::]")?.canonical == "::")
    }

    @Test func zoneSuffixedUnspecifiedIsSensitive() {
        #expect(PolicyDiffRisk.isSensitive("::%lo0"))
        #expect(PolicyDiffRisk.normalize("fe80::1%en0")?.canonical == "fe80::1")
        #expect(PolicyDiffRisk.isSensitive("fe80::1%en0"))
    }

    @Test func aliasesNormalizeToTheSameCanonicalBytes() {
        let short = PolicyDiffRisk.normalize("::")
        let expanded = PolicyDiffRisk.normalize("0:0:0:0:0:0:0:0")
        #expect(short == expanded)
        let mapped = PolicyDiffRisk.normalize("::FFFF:127.0.0.1")
        #expect(mapped?.canonical == "::ffff:127.0.0.1")
        #expect(mapped.map { PolicyDiffRisk.isSensitive(normalized: $0) } == true)
    }

    @Test func publicLiteralsStayRoutine() {
        #expect(PolicyDiffRisk.isSensitive("1.1.1.1") == false)
        #expect(PolicyDiffRisk.isSensitive("8.8.8.8") == false)
        #expect(PolicyDiffRisk.isSensitive("2001:4860:4860::8888") == false)
        #expect(PolicyDiffRisk.isSensitive("::ffff:1.1.1.1") == false)
    }

    @Test func unparseableInputFailsClosedToSensitive() {
        #expect(PolicyDiffRisk.isSensitive("not-an-ip"))
        #expect(PolicyDiffRisk.isSensitive(""))
        #expect(PolicyDiffRisk.isSensitive("1.2.3.4:443"))
        #expect(PolicyDiffRisk.assess(hosts: ["1.1.1.1", "not-an-ip"]) == .sensitive)
    }

    @Test func assessFlagsADiffWithAnySensitiveHost() {
        #expect(PolicyDiffRisk.assess(hosts: []) == .routine)
        #expect(PolicyDiffRisk.assess(hosts: ["1.1.1.1", "8.8.8.8"]) == .routine)
        #expect(PolicyDiffRisk.assess(hosts: ["1.1.1.1", "::"]) == .sensitive)
        #expect(PolicyDiffRisk.assess(hosts: ["::ffff:10.0.0.1"]) == .sensitive)
    }
}
